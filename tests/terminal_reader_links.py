#!/usr/bin/env python3
"""Titled link chooser in owned PTYs: synthetic fixture mail, no live browser.

Fixture mode validates browser.open without launching anything, and the TUI
echoes the validated literal target, so this test observes exactly what Enter
or a click submitted. Run under the cooperative host lock.
"""
import argparse
import base64
import copy
import json
import hashlib
from pathlib import Path
import sys
import tempfile

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start, click, point
from terminal_reader import reader_contains

SELECTED = ("rgb", 57, 43, 48)
TAB = b"\t"
ENTER = b"\r"
FIRST = "https://example.test/fixture-first"
BARE = "https://example.test/fixture-bare"
ACTUAL = "https://example.test/fixture-actual"
FINAL = "https://example.test/fixture-final?a=1&b=(2)!"
MISLEADING = "https://bank.example/login"
PLAIN = f"LINKS-FIXTURE plain {FIRST} and {BARE}\n"
HTML = ("<p>LINKS-FIXTURE html</p>"
        f'<p><a href="{FIRST}">Review <b>API</b> Keys</a></p>'
        f'<p><a href="{BARE}">{BARE}</a></p>'
        f'<p><a href="{ACTUAL}">{MISLEADING}</a></p>'
        '<p><a href="https://example.test/fixture-final?a=1&amp;b=(2)!">Final <i>fixture</i> link</a></p>')


def encoded(value):
    raw = value.encode()
    return {"size": len(raw), "data": base64.urlsafe_b64encode(raw).decode().rstrip("=")}


def fixture_setup(binary, directory):
    fixture = ProviderFixture(directory)
    for account in ACCOUNTS:
        message = next(value for value in fixture.data[account]["baseline"]["messages"] if value["id"] == "shared-msg-096")
        root = message["payload"]
        parts = []
        for part_id, mime, content in (("0", "text/plain", PLAIN), ("1", "text/html", HTML)):
            part = copy.deepcopy(root)
            part.pop("parts", None)
            part["partId"] = part_id
            part["mimeType"] = mime
            part["headers"] = [{"name": "Content-Type", "value": f"{mime}; charset=utf-8"}]
            part["body"] = encoded(content)
            parts.append(part)
        root["mimeType"] = "multipart/alternative"
        root["body"] = {"size": 0, "data": ""}
        content_type = "multipart/alternative; boundary=fixture-links"
        if not any(header["name"].lower() == "content-type" for header in root["headers"]):
            root["headers"].append({"name": "Content-Type", "value": content_type})
        for header in root["headers"]:
            if header["name"].lower() == "content-type":
                header["value"] = content_type
        root["parts"] = parts
        fixture.stage(account, "baseline")
    with Client(binary, directory, extra=fixture.options()) as client:
        for account in ACCOUNTS:
            client.request("mail.refresh", account, limit=40, prefetchLimit=40)
            client.request("mail.read", account, messageId="shared-msg-096")
    return fixture


def cells(terminal, row, column, width):
    return "".join(terminal.screen.cells[row][column:column + width])


def background(terminal, row, column):
    return terminal.screen.styles[row][column][1]


def foreground(terminal, row, column):
    return terminal.screen.styles[row][column][0]


def chooser(terminal):
    """Rows of the four synthetic entries, located from exact destination rows."""
    found = {name: terminal.screen.locate("-> " + url) for name, url in
             (("first", FIRST), ("bare", BARE), ("actual", ACTUAL), ("final", FINAL))}
    if any(value is None for value in found.values()):
        return None
    return {"column": found["first"]["column"] - 4, **{name: value["row"] for name, value in found.items()},
            "indent": {name: value["column"] for name, value in found.items()}}


def open_chooser(terminal):
    terminal.send(b"L")
    terminal.until(lambda: "Links · explicit browser open" in terminal.text() and chooser(terminal) is not None)
    return chooser(terminal)


def require_layout(terminal, rows):
    column = rows["column"]
    require(cells(terminal, rows["first"] - 1, column, 15) == "Review API Keys", "nested anchor title absent above its destination")
    require(cells(terminal, rows["first"], column, 7) == "    -> ", "titled destination is not indented under an arrow")
    require(rows["bare"] == rows["first"] + 1 and rows["indent"]["bare"] == column,
            "bare URL gained a title row or indentation")
    require(cells(terminal, rows["actual"] - 1, column, len(MISLEADING)) == MISLEADING
            and rows["actual"] == rows["bare"] + 2 and rows["indent"]["actual"] == column + 4,
            "URL-shaped label did not stay a literal title above the real destination")
    require(cells(terminal, rows["final"] - 1, column, 18) == "Final fixture link"
            and rows["final"] == rows["actual"] + 2 and rows["indent"]["final"] == column + 4,
            "final titled entry is not two whole rows")


def selected(terminal, row, column):
    return background(terminal, row, column) == SELECTED


def writes_snapshot(binary, directory, fixture):
    with Client(binary, directory, extra=fixture.options()) as client:
        accounts = {account: {
            key: client.request("cache.stats", account)[key]
            for key in ("fixtureCalls", "fixtureSends")
        } for account in ACCOUNTS}
    # Cache/UI persistence is expected; received-file destinations must stay untouched.
    home = directory / "home"
    files = {str(path.relative_to(home)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in home.rglob("*") if path.is_file()}
    return {"accounts": accounts, "homeFiles": files,
            "downloadsExists": (home / "Downloads").exists()}


def color_case(binary, directory):
    fixture = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "LINKS-FIXTURE"))
        before = writes_snapshot(binary, directory, fixture)
        rows = open_chooser(terminal)
        column = rows["column"]
        require_layout(terminal, rows)
        require(selected(terminal, rows["first"] - 1, column) and selected(terminal, rows["first"], column),
                "initial selection did not cover both rows of the first entry")
        require(not selected(terminal, rows["final"] - 1, column), "unselected entry rendered as selected")
        require(foreground(terminal, rows["final"] - 1, column) != foreground(terminal, rows["final"], rows["indent"]["final"] + 3),
                "title shares the destination colour")
        # Navigate to the final entry; one more j keeps it there.
        for _ in range(8):
            if selected(terminal, rows["final"] - 1, column):
                break
            terminal.send(b"j")
            terminal.gap(.06)
        terminal.until(lambda: selected(terminal, rows["final"] - 1, column) and selected(terminal, rows["final"], column))
        terminal.send(b"j")
        terminal.gap(.1)
        require(selected(terminal, rows["final"], column) and not selected(terminal, rows["first"], column),
                "final synthetic link is not the last chooser entry")
        terminal.send(b"k")
        terminal.until(lambda: selected(terminal, rows["actual"], column))
        # Either row of an entry selects that same entry.
        click(terminal, column + 2, rows["first"] - 1)
        terminal.until(lambda: selected(terminal, rows["first"], column) and not selected(terminal, rows["actual"], column))
        click(terminal, rows["indent"]["final"] + 8, rows["final"])
        terminal.until(lambda: selected(terminal, rows["final"] - 1, column) and not selected(terminal, rows["first"] - 1, column))
        # Footer focus then Enter opens the selected exact destination.
        terminal.send(TAB)
        terminal.until(lambda: (found := terminal.screen.locate("[Enter Open]")) is not None
                       and selected(terminal, found["row"], found["column"]))
        terminal.send(ENTER)
        terminal.until(lambda: f"Mock browser target validated · {FINAL}" in terminal.text()
                       and "Links · explicit browser open" not in terminal.text())
        # A fresh chooser starts at the first entry; clicking the footer button opens it.
        rows = open_chooser(terminal)
        require_layout(terminal, rows)
        click(terminal, *point(terminal, "[Enter Open]"))
        terminal.until(lambda: f"Mock browser target validated · {FIRST}" in terminal.text()
                       and "Links · explicit browser open" not in terminal.text())
        # Narrow chooser: whole two-row entries, ellipsized only within the panel.
        terminal.resize(48, 24)
        terminal.until(lambda: reader_contains(terminal.screen, "LINKS-FIXTURE") or "Mail ·" in terminal.text())
        terminal.send(b"L")
        terminal.until(lambda: "[Enter Open]" in terminal.text() and "[q Back]" in terminal.text()
                       and terminal.screen.locate("-> " + FIRST) is not None)
        first = terminal.screen.locate("-> " + FIRST)
        require(cells(terminal, first["row"] - 1, first["column"] - 4, 15) == "Review API Keys",
                "narrow chooser lost the title row")
        final = terminal.screen.locate("    -> https://example.test/fixture-fin")
        require(final is not None and cells(terminal, final["row"] - 1, final["column"], 18) == "Final fixture link",
                "narrow chooser split or dropped the final entry")
        require(terminal.screen.locate("[Enter Open]")["row"] > final["row"], "list rows overlapped the footer buttons")
        reach = 0
        while not (found := terminal.screen.locate("[q Back]")) or not selected(terminal, found["row"], found["column"]):
            require(reach < 4, "Back button is not keyboard reachable")
            terminal.send(TAB)
            terminal.gap(.06)
            reach += 1
        terminal.send(ENTER)
        terminal.until(lambda: "[Enter Open]" not in terminal.text())
        require(writes_snapshot(binary, directory, fixture) == before, "link chooser mutated provider state or created received files")
        terminal.finish()
        print("PASS reader links: titled/bare rows, final-entry navigation, both-row mouse selection, focused Enter and button open exact URLs, zero provider/file writes")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def no_color_case(binary, directory):
    fixture = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture, environment={"NO_COLOR": "1"})
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "LINKS-FIXTURE"))
        rows = open_chooser(terminal)
        require_layout(terminal, rows)
        terminal.send(b"\x1b")
        terminal.until(lambda: "Links · explicit browser open" not in terminal.text())
        terminal.finish()
        print("PASS reader links no-color: title, arrow and indentation carry the structure")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=("color", "no-color", "all"), default="all")
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-reader-links-") as temporary:
        root = Path(temporary)
        if args.case in ("color", "all"):
            color_case(binary, root / "color")
        if args.case in ("no-color", "all"):
            no_color_case(binary, root / "no-color")
    print(json.dumps({"readerLinks": True, "syntheticOnly": True, "liveBrowser": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
