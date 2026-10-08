#!/usr/bin/env python3
"""Owned-PTY formatted-original chooser, note editor and saved snapshot checks.

All mail/accounts are synthetic. No desktop input, credentials or mail send is
used. Run only in the coordinator's granted cooperative host test window.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import shlex
import sys
import tempfile

from build_info import read_build_info
from terminal_formatted_original import (
    FormattedFixture, NOTE, SOURCE_ID, SOURCE_THREAD, check_snapshot, decoded, part,
)
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import click, point, start
from terminal_polish_compose import panel_text


CASES = ("chooser", "lifecycle", "modes", "queued")
EDITOR_NOTE = "Editor personal note.\nOnly this note was edited.\n"


def prepare(binary, directory, body=True):
    fixture = FormattedFixture(directory)
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.refresh", limit=40, prefetchLimit=0)
        if body:
            client.request("mail.read", messageId=SOURCE_ID)
    return fixture


def wait_mail(terminal):
    terminal.until(lambda: "Original layout for personal@example.com" in terminal.text()
                   and "Subject:" not in terminal.text())


def wait_chooser(terminal, forward=False):
    terminal.until(lambda: "[Keep formatting k]" in terminal.text() and "[Text quote t]" in terminal.text()
                   and "[Back Esc/q]" in terminal.text())
    require(("[Attach original .eml e]" in terminal.text()) == forward, "chooser exposed the wrong reply/forward actions")


def wait_compose(terminal, mode="formatted original"):
    terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text()
                   and mode in terminal.text() and "[Keep formatting k]" not in terminal.text())


def drafts(binary, directory, fixture):
    with Client(binary, directory, extra=fixture.options()) as client:
        rows = client.request("draft.list")["drafts"]
        values = [client.request("draft.read", draftId=row["id"]) for row in rows]
        require(client.request("cache.stats")["fixtureSends"] == 0, "TUI test submitted mail")
        require(client.request("operation.list")["operations"] == [], "TUI test created a submission operation")
        return values


def single_draft(binary, directory, fixture):
    values = drafts(binary, directory, fixture)
    require(len(values) == 1, "chooser/editor changed the draft count")
    return values[0]


def normal(terminal):
    terminal.send(b"\x1b")
    terminal.gap(.07)


def paste(terminal, value):
    terminal.send(b"\x1b[200~" + value.encode() + b"\x1b[201~")


def button_background(terminal, label):
    x, y = point(terminal, label)
    return terminal.screen.styles[y][x][1]


def diagnose(terminal, stage):
    print(json.dumps({"stage": stage, "currentCells": terminal.screen.lines(),
                      "outputBytes": terminal.output_total}))


def chooser(binary, directory):
    fixture = prepare(binary, directory)
    terminal = start(binary, directory, fixture, columns=100, rows=30)
    stage = "reply chooser"
    try:
        wait_mail(terminal)
        for key in (b"r", b"R", b"f", b"F"):
            forward = key.lower() == b"f"
            terminal.send(key)
            wait_chooser(terminal, forward)
            selected = button_background(terminal, "[Keep formatting k]")
            require(selected != button_background(terminal, "[Text quote t]"), "default format action lacks visible focus")
            terminal.send(b"\t")
            terminal.until(lambda: button_background(terminal, "[Text quote t]") == selected)
            terminal.send(b"\x1b[Z")
            terminal.until(lambda: button_background(terminal, "[Keep formatting k]") == selected)
            terminal.send(b"\x1b[Z")
            terminal.until(lambda: button_background(terminal, "[Back Esc/q]") == selected)
            # Modal keys and backdrop clicks cannot retarget account/message.
            terminal.send(b"2j")
            click(terminal, 0, 0)
            wait_chooser(terminal, forward)
            require(drafts(binary, directory, fixture) == [], "opening chooser created a partial draft")
            terminal.send(b"\r")
            terminal.until(lambda: "[Keep formatting k]" not in terminal.text())
            require(drafts(binary, directory, fixture) == [], "Back created a draft")
        stage = "narrow chooser mouse cancel"
        terminal.resize(30, 10)
        terminal.send(b"F")
        wait_chooser(terminal, True)
        for label in ("[Keep formatting k]", "[Text quote t]", "[Attach original .eml e]", "[Back Esc/q]"):
            point(terminal, label)
        click(terminal, *point(terminal, "[Back Esc/q]"))
        terminal.until(lambda: "[Keep formatting k]" not in terminal.text())
        require(drafts(binary, directory, fixture) == [], "mouse cancel created a partial draft")
        terminal.resize(100, 30)
        terminal.send(b"r")
        wait_chooser(terminal)
        terminal.send(b"q")
        terminal.until(lambda: "[Keep formatting k]" not in terminal.text())
        terminal.send(b"r")
        wait_chooser(terminal)
        normal(terminal)
        terminal.until(lambda: "[Keep formatting k]" not in terminal.text())
        return terminal.finish()
    except Exception:
        diagnose(terminal, stage)
        raise
    finally:
        terminal.close()


def lifecycle_one(binary, directory, forward):
    fixture = prepare(binary, directory)
    editor = directory / "note_editor.py"
    editor.write_text(
        "from pathlib import Path\nimport sys\n"
        "target = Path(sys.argv[-1])\n"
        "Path('editor-note-input.txt').write_text(target.read_text())\n"
        f"target.write_text({EDITOR_NOTE!r})\n"
    )
    terminal = start(binary, directory, fixture, columns=160, rows=42,
                     environment={"EDITOR": shlex.join([sys.executable, str(editor)])})
    stage = "create formatted draft"
    try:
        wait_mail(terminal)
        terminal.send(b"f" if forward else b"r")
        wait_chooser(terminal, forward)
        if forward:
            click(terminal, *point(terminal, "[Keep formatting k]"))
        else:
            terminal.send(b"\r")
        wait_compose(terminal)
        initial = single_draft(binary, directory, fixture)
        original = copy.deepcopy(check_snapshot(initial))
        require(initial["bodyText"] == "" and len(initial["attachments"]) == int(forward), "formatted composer copied source into note or duplicated files")
        require("Original layout" not in panel_text(terminal, "Compose"), "received source entered editable composer pane")
        stage = "note entry and preflight"
        if forward:
            terminal.send(b"\x13")
            terminal.until(lambda: "Add a recipient in To, Cc or Bcc" in terminal.text())
            require(single_draft(binary, directory, fixture)["original"] == original, "missing-recipient preflight changed snapshot")
            terminal.send(b"irecipient@example.test")
            normal(terminal)
        terminal.send(b"\x07i")
        paste(terminal, NOTE)
        terminal.until(lambda: "Personal note" in panel_text(terminal, "Compose"))
        normal(terminal)
        terminal.send(b"\x14")
        terminal.until(lambda: "Plain · Body:" in terminal.text())
        terminal.send(b"p")
        terminal.until(lambda: "Original message · saved snapshot" in terminal.text()
                       and "Original layout" in panel_text(terminal, "Original message"))
        click(terminal, *point(terminal, "Original layout"))
        terminal.until(lambda: "Original is protected" in terminal.text())
        stage = "external editor sees only note"
        terminal.send(b"e")
        terminal.until(lambda: (directory / "editor-note-input.txt").is_file()
                       and "Compose" in terminal.text()
                       and "Editor personal note." in panel_text(terminal, "Compose"))
        require((directory / "editor-note-input.txt").read_text() == NOTE, "external editor received original HTML/text/resources")
        stage = "ordinary attachment edits preserve embedded resources"
        extra_file = directory / "note-extra.txt"
        extra_file.write_bytes(b"Synthetic note attachment\n")
        terminal.send(b"A")
        terminal.until(lambda: "Attach file · local draft" in terminal.text())
        terminal.send(str(extra_file).encode() + b"\r")
        terminal.until(lambda: "note-extra.txt" in terminal.text() and "Attach file · local draft" not in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text())
        with_extra = single_draft(binary, directory, fixture)
        require(with_extra["original"] == original and len(with_extra["attachments"]) == int(forward) + 1,
                "adding ordinary attachment changed protected resources")
        normal(terminal)
        wait_compose(terminal)
        file_at = terminal.screen.locate("note-extra.txt")
        require(file_at is not None, "new ordinary file is not removable")
        row = "".join(terminal.screen.cells[file_at["row"]])
        click(terminal, row.index("[x]") + 1, file_at["row"])
        terminal.until(lambda: "note-extra.txt" not in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text() and "Original: HTML retained" in terminal.text())
        saved = single_draft(binary, directory, fixture)
        require(saved["original"] == original and saved["bodyText"] == EDITOR_NOTE and saved["bodyFormat"] == "plain", "editor/save changed original or note format")
        require(not any(item["filename"].endswith(".eml") for item in saved["attachments"]), "primary formatted flow attached an email instead of inline original")
        require("3 embedded resources" in terminal.text(), "send review omitted original embedded-resource count")
        terminal.finish()
    except Exception:
        diagnose(terminal, stage)
        raise
    finally:
        terminal.close()
    # The saved Original must remain usable with both the provider source and
    # source body cache absent, including the read-only snapshot preview.
    fixture.sources[ACCOUNTS[0]]["messages"] = []
    fixture.sources[ACCOUNTS[0]]["externalBodies"] = {}
    fixture.save()
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("cache.clear")
    terminal = start(binary, directory, fixture, columns=160, rows=42)
    try:
        terminal.until(lambda: terminal.screen.locate("Drafts") is not None)
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Drafts" in terminal.screen.lines()[0] and "Synthetic formatted original" in terminal.text())
        terminal.send(b"\r")
        wait_compose(terminal)
        terminal.send(b"p")
        terminal.until(lambda: "Original message · saved snapshot" in terminal.text()
                       and "Original layout" in panel_text(terminal, "Original message"))
        terminal.resize(70, 24)
        terminal.until(lambda: terminal.screen.cells[2][69] in "╮┐╗")
        terminal.send(b"p")
        terminal.until(lambda: "Original message · saved snapshot" in terminal.text() and "[Back]" in terminal.text())
        terminal.send(b"\t\t\r")
        wait_compose(terminal)
        require(single_draft(binary, directory, fixture)["original"] == original, "reopened narrow preview changed snapshot")
        return terminal.finish()
    except Exception:
        diagnose(terminal, "reopen snapshot without source")
        raise
    finally:
        terminal.close()


def lifecycle(binary, directory):
    return [lifecycle_one(binary, directory / name, forward) for name, forward in (("reply", False), ("forward", True))]


def modes(binary, directory):
    results = []
    for choice, via_mouse in (("text", False), ("text", True), ("attached", False), ("attached", True), ("plain", False)):
        current = directory / (choice + ("-mouse" if via_mouse else "-key"))
        fixture = prepare(binary, current)
        if choice == "plain":
            message = fixture.message()
            headers = message["payload"]["headers"]
            message["payload"] = part("text/plain", b"PLAIN LEGACY SOURCE\n")
            message["payload"]["headers"] += headers
            fixture.save()
            with Client(binary, current, extra=fixture.options()) as client:
                client.request("cache.clear")
                client.request("mail.read", messageId=SOURCE_ID)
        terminal = start(binary, current, fixture, columns=100, rows=32)
        try:
            terminal.until(lambda: ("PLAIN LEGACY SOURCE" if choice == "plain" else "Original layout") in terminal.text())
            terminal.send(b"F")
            if choice != "plain":
                wait_chooser(terminal, True)
                if via_mouse:
                    click(terminal, *point(terminal, "[Attach original .eml e]" if choice == "attached" else "[Text quote t]"))
                else:
                    terminal.send(b"e" if choice == "attached" else b"t")
            terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text())
            value = single_draft(binary, current, fixture)
            require(value.get("original") is None, "explicit text/eml or plain source created formatted snapshot")
            require(not value["threadId"] and not value["references"], "forward retained old thread")
            if choice == "attached":
                require("original attached" in terminal.text() and len(value["attachments"]) == 1
                        and decoded(value["attachments"][0]["data"]) == fixture.raw_sources[ACCOUNTS[0]],
                        ".eml choice lost original source bytes or title")
            else:
                require("Forwarded message" in value["bodyText"], "text quote failed to retain editable original")
                require("[Keep formatting k]" not in terminal.text(), "plain source unnecessarily opened chooser")
            results.append(terminal.finish())
        except Exception:
            diagnose(terminal, choice)
            raise
        finally:
            terminal.close()
    return results


def queued(binary, directory):
    fixture = prepare(binary, directory, body=False)
    second = copy.deepcopy(fixture.message())
    second.update(id="different-selected-message", internalDate="1799998990000")
    fixture.sources[ACCOUNTS[0]]["messages"].append(second)
    hold, entered = fixture.root / "source.hold", fixture.root / "source.entered"
    hold.write_text("Synthetic body is pending\n")
    fixture.sources[ACCOUNTS[0]]["sync"]["fixtureProgress"] = {
        "phase": "bodies", "completed": 0, "fixtureHold": hold.name, "fixtureEntered": entered.name,
    }
    fixture.save()
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.list", limit=40)
    terminal = start(binary, directory, fixture, columns=120, rows=34)
    try:
        terminal.until(lambda: entered.is_file())
        terminal.send(b"rj")
        terminal.gap(.15)
        # The synthetic body gate deliberately holds the account lock. Read
        # its committed index directly rather than starting a competing API
        # request whose CacheBusy error would obscure the queued-UI oracle.
        indices = list((directory / "cache" / "fixtures").glob("*/index.json"))
        require(indices and all(json.loads(path.read_text()).get("drafts", []) == [] for path in indices),
                "queued read created a draft before source was ready")
        hold.unlink()
        wait_chooser(terminal)
        terminal.send(b"k")
        wait_compose(terminal)
        value = single_draft(binary, directory, fixture)
        require(value["original"]["sourceMessageId"] == SOURCE_ID and value["threadId"] == SOURCE_THREAD,
                "queued formatted reply followed later cursor selection")
        check_snapshot(value)
        return terminal.finish()
    except Exception:
        diagnose(terminal, "queued source identity")
        raise
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    result = {}
    with tempfile.TemporaryDirectory(prefix="omagma-formatted-tui-") as temporary:
        for case in args.case or CASES:
            result[case] = globals()[case](binary, Path(temporary) / case)
            print(f"PASS formatted TUI {case}")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested TUI binary changed")
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps({"suite": "terminal-formatted-tui", "status": "passed",
            "synthetic": True, "liveProviderWrites": 0, "fixtureSends": 0, "binarySha256": digest,
            "cases": result, **read_build_info(binary, None)}, indent=2) + "\n")


if __name__ == "__main__":
    main()
