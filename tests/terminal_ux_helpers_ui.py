#!/usr/bin/env python3
"""Saved-search and contact-address workflows in synthetic owned PTYs.

Uses only fictional provider fixtures and task-owned preferences/cache. Runtime
execution requires the coordinator's cooperative host window. No mail is sent
and the contact editor is cancelled without saving.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil

from terminal_integration import ACCOUNTS, FIXTURES, Client, require
from terminal_mouse import MouseTerminal
from terminal_ux_batch_navigation import MARKER, fixtures
from terminal_ux_batch_support import (TAB, ENTER, ESC, FocusScreen,
    activate_button, capture, command, diagnose, no_writes, read_draft,
    run_cases, start, wait_send_review, wait_ux_dialog)


def search(terminal, query, scope):
    terminal.send((b"/" if scope == "cache" else b"\\") + b"\x15" + query.encode() + ENTER)
    title = "Cache search" if scope == "cache" else "Gmail search"
    terminal.until(lambda: title in terminal.screen.lines()[0])
    terminal.gap(.1)


def clear_search(terminal):
    terminal.send(b"q")
    terminal.until(lambda: "Cache search" not in terminal.screen.lines()[0]
                   and "Gmail search" not in terminal.screen.lines()[0])


def saved_rows(directory):
    value = json.loads((directory / "fixture-ui.json").read_text())
    return {(row["account"], row["name"]): (row["query"], row["mode"])
            for row in value.get("savedSearches", [])}


def reopen_search(terminal, name, query, scope, account):
    command(terminal, "saved-searches")
    wait_ux_dialog(terminal, "Saved searches", "[Open]", name)
    terminal.send(name.encode())  # Filter leaves exactly the named entry.
    title = "Cache" if scope == "cache" else "Gmail"
    terminal.until(lambda: f"{title} · {query}" in terminal.text())
    activate_button(terminal, "[Open]")
    terminal.until(lambda: "Saved searches" not in terminal.text()
                   and f"{title} search" in terminal.screen.lines()[0]
                   and account in terminal.screen.lines()[0])
    # Read the reopened query through the ordinary search field. Merely seeing
    # the saved label/scope in the chooser would not prove it was applied.
    terminal.send(b"/" if scope == "cache" else b"\\")
    prompt = "Cache / " if scope == "cache" else "Gmail \\ "
    terminal.until(lambda: f"{prompt}{query}▏" in terminal.screen.lines()[-2])
    terminal.send(ESC)
    terminal.gap(.08)
    require(f"{title} search" in terminal.screen.lines()[0],
            "cancelling query inspection changed the restored search scope")


def saved_searches(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    extra = source.options()
    cache_name, gmail_name = "Fixture focus", "Fixture provider"
    cache_query = "subject:personal is:unread"
    gmail_query = "subject:personal"
    work_query = "subject:work is:unread"
    terminal = start(binary, directory, extra, MARKER)
    try:
        search(terminal, cache_query, "cache")
        command(terminal, "save-search")
        wait_ux_dialog(terminal, "Save search · name", "[Save]", filtered=False)
        terminal.send(cache_name.encode())
        activate_button(terminal, "[Save]")
        terminal.until(lambda: "Search saved for this account" in terminal.text())
        clear_search(terminal)
        search(terminal, gmail_query, "server")
        command(terminal, f"save-search {gmail_name}")
        terminal.until(lambda: "Search saved for this account" in terminal.text())
        clear_search(terminal)

        terminal.send(b"2")
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0])
        command(terminal, "saved-searches")
        wait_ux_dialog(terminal, "Saved searches", "[Open]", "No matching actions or entries")
        require(cache_name not in terminal.text() and gmail_name not in terminal.text(),
                "another account displayed the personal saved searches")
        activate_button(terminal, "[Back]")
        search(terminal, work_query, "cache")
        command(terminal, f"save-search {cache_name}")
        terminal.until(lambda: "Search saved for this account" in terminal.text())
        clear_search(terminal)
        expected = {(ACCOUNTS[0], cache_name): (cache_query, "cache"),
                    (ACCOUNTS[0], gmail_name): (gmail_query, "server"),
                    (ACCOUNTS[1], cache_name): (work_query, "cache")}
        require(saved_rows(directory) == expected,
                "saving the same name in two accounts lost a query, scope, or account")

        # Restart against the same preferences; support.start intentionally
        # initializes a fresh file, so construct this second terminal directly.
        terminal.finish()
        terminal.close()
        terminal = None
        terminal = MouseTerminal(binary, directory,
            extra=(*extra, "--ui-file", str(directory / "fixture-ui.json")),
            columns=160, rows=40, screen_type=FocusScreen,
            environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0] and MARKER in terminal.text())
        reopen_search(terminal, cache_name, work_query, "cache", ACCOUNTS[1])
        clear_search(terminal)
        terminal.send(b"1")
        terminal.until(lambda: ACCOUNTS[0] in terminal.screen.lines()[0])
        reopen_search(terminal, cache_name, cache_query, "cache", ACCOUNTS[0])
        capture(terminal, capture_dir, "ux-saved-cache-reopened")
        clear_search(terminal)
        reopen_search(terminal, gmail_name, gmail_query, "server", ACCOUNTS[0])
        capture(terminal, capture_dir, "ux-saved-gmail-reopened")
        require(saved_rows(directory) == expected, "reopening changed the saved search records")
        clear_search(terminal)
        no_writes(binary, directory, extra)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("operation.list", account=ACCOUNTS[1])["operations"] == [],
                    "saved-search navigation dispatched a provider write for the second account")
        terminal.finish()
    except Exception:
        if terminal is not None:
            diagnose(terminal)
        raise
    finally:
        if terminal is not None:
            terminal.close()


def contact_fixture(binary, directory, display_name, first, second):
    fixture = directory / "fixture"
    shutil.copytree(FIXTURES, fixture, ignore=shutil.ignore_patterns("__pycache__"))
    path = fixture / "contacts/personal.json"
    provider = json.loads(path.read_text())
    contact = provider["connections"][0]
    contact["names"][0]["displayName"] = display_name
    contact["emailAddresses"] = [{"value": first, "type": "work"},
                                  {"value": second, "type": "home"}]
    path.write_text(json.dumps(provider, ensure_ascii=False) + "\n")
    extra = ("--fixture-root", str(fixture))
    with Client(binary, directory, extra=extra) as client:
        client.request("mail.list", limit=32)
        body = client.request("mail.read", messageId="shared-msg-096")
        contacts = client.request("contacts.list")["contacts"]
        selected = next(value for value in contacts if value["name"] == display_name)
        require([value["address"] for value in selected["emails"]] == [first, second],
                "provider setup did not preserve both contact addresses")
    return extra, body, contacts


def contact_second_address(binary, directory, capture_dir=None):
    display_name = 'River, "Café"'
    first, second = "river-first@example.test", "river-second@example.test"
    extra, body, original_contacts = contact_fixture(binary, directory, display_name, first, second)
    opening = body["bodyText"].splitlines()[0]
    formatted = json.dumps(display_name, ensure_ascii=False) + f" <{second}>"
    terminal = start(binary, directory, extra, opening)
    try:
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Attachments 0" in terminal.text())
        terminal.send(b"irecipient@example.test" + TAB + ESC)
        terminal.gap(.08)
        terminal.send(b"a")
        terminal.until(lambda: "Choose recipient" in terminal.text() and display_name in terminal.text())
        terminal.send(ENTER)
        wait_ux_dialog(terminal, "Choose contact address", "[Use]", first, second)
        terminal.send(b"\x0e")  # Ctrl+N explicitly chooses the second address.
        capture(terminal, capture_dir, "ux-contact-second-address")
        activate_button(terminal, "[Use]")
        terminal.until(lambda: f"Cc: {formatted}" in terminal.text() and "Subject:" in terminal.text())
        require("To: recipient@example.test" in terminal.text(),
                "choosing a Cc address replaced the existing To recipient")
        terminal.send(b"i" + TAB * 2 + b"Second contact address" + TAB + b"Fixture note." + ESC)
        terminal.gap(.08)
        terminal.send(b"\x13")  # Save locally and review; never confirm send.
        wait_send_review(terminal)
        draft = read_draft(binary, directory, extra)
        require([value["address"] for value in draft["to"]] == ["recipient@example.test"],
                "contact picker altered the existing To recipient")
        require(draft["cc"] == [{"address": second, "name": display_name}],
                "local draft lost the selected second address or its full display name")
        require(draft["bcc"] == [] and draft["subject"] == "Second contact address"
                and draft["bodyText"] == "Fixture note.", "contact choice changed unrelated draft fields")
        activate_button(terminal, "[Back]")
        terminal.until(lambda: "Review send" not in terminal.screen.lines()[0])
        terminal.send(b"q")
        terminal.until(lambda: "Mail ·" in terminal.text() and "Compose" not in terminal.screen.lines()[0])
        terminal.send(ENTER)
        terminal.until(lambda: opening in terminal.text())

        command(terminal, "add-contact")
        terminal.until(lambda: "Edit contact" in terminal.screen.lines()[0]
                       and "Name:" in terminal.text() and "Email:" in terminal.text()
                       and "[Cancel]" in terminal.text())
        require(body["from"]["name"] in terminal.text() and body["from"]["address"] in terminal.text(),
                "add sender to contacts did not prefill the focused sender")
        capture(terminal, capture_dir, "ux-sender-contact-prefill")
        activate_button(terminal, "[Cancel]")
        terminal.until(lambda: "Edit contact" not in terminal.screen.lines()[0])
        with Client(binary, directory, extra=extra) as client:
            require(client.request("contacts.list", cacheOnly=True)["contacts"] == original_contacts,
                    "choosing an address or cancelling sender prefill changed stored contacts")
        no_writes(binary, directory, extra)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def main():
    cases = (("saved-searches", saved_searches), ("contact-second-address", contact_second_address))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=[name for name, _ in cases], action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    run_cases(args.binary, cases, args.case, args.capture_dir)


if __name__ == "__main__":
    main()
