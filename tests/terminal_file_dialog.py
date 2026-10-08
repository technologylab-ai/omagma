#!/usr/bin/env python3
"""Focused file-dialog acceptance in owned fixture PTYs; no desktop windows.

Run only in the root agent's granted host window. Optional captures reconstruct
current VT cells as SVG/PNG; they contain only this script's fictional fixtures.
"""
from __future__ import annotations

import argparse
import base64
import copy
import html
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import traceback

from terminal_cache import ProviderFixture
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import click, point, report, start
from terminal_reader import reader_contains, reader_rectangle

CASES = ("attach-new", "attach-reply", "attach-all", "attach-forward",
         "save", "missing-downloads", "browser-thread", "keyboard", "tab-buttons")
FIRST = b"Fictional report attachment only.\n"
SECOND = b"Fictional meeting notes only.\n"
PAYLOADS = {"nested packet.txt": b"Nested outgoing fixture.\n",
            "qjk café notes.txt": b"Literal Unicode outgoing fixture.\n"}


def fixture_setup(binary, directory):
    source = ProviderFixture(directory)
    (directory / "home").mkdir(mode=0o700)
    for account in ACCOUNTS:
        for message in source.data[account]["baseline"]["messages"]:
            if message["id"] not in {"shared-msg-094", "shared-msg-095", "shared-msg-096"}:
                continue
            number = message["id"][-3:]
            content = (f"Fictional file-dialog message {number}.\n\nHello Morgan,\n\n"
                       "The launch notes are ready for your review.\n"
                       "Preview: https://example.test/launch\n\nThanks,\nMaya\n")
            data = content.encode()
            for header in message["payload"]["headers"]:
                if header["name"].lower() == "subject":
                    header["value"] = "Launch notes — ready for review"
                elif header["name"].lower() == "from":
                    header["value"] = "Maya Chen <maya@example.org>"
            message["payload"]["body"] = {"size": len(data), "data": b64(data)}
            if number != "096":
                continue
            plain = copy.deepcopy(message["payload"])
            plain.update(partId="0", mimeType="text/plain",
                         headers=[{"name": "Content-Type", "value": "text/plain; charset=utf-8"}])
            mixed = message["payload"]
            mixed.update(mimeType="multipart/mixed", body={"size": 0, "data": ""}, parts=[plain])
            for header in mixed["headers"]:
                if header["name"].lower() == "content-type":
                    header["value"] = "multipart/mixed; boundary=file-dialog-fixture"
            for index, (name, payload) in enumerate((("report.txt", FIRST), ("meeting notes.txt", SECOND)), 1):
                mixed["parts"].append({"partId": str(index), "mimeType": "application/octet-stream", "filename": name,
                    "headers": [{"name": "Content-Disposition", "value": f'attachment; filename="{name}"'}],
                    "body": {"size": len(payload), "data": b64(payload)}})
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("mail.refresh", limit=32, prefetchLimit=4)
        client.request("mail.thread", threadId="shared-thread-031")
    return source


def b64(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def rectangle(terminal, title, required=True):
    found = terminal.screen.locate(title)
    if found is None:
        require(not required, f"expected current modal title missing: {title}")
        return None
    row = terminal.screen.cells[found["row"]]
    left = next((x for x in range(found["column"], -1, -1) if row[x] in "╭┌╔"), None)
    right = next((x for x in range(found["column"], terminal.columns) if row[x] in "╮┐╗"), None)
    if left is None or right is None:
        require(not required, "modal top border missing")
        return None
    bottom = next((y for y in range(found["row"] + 1, terminal.rows)
                   if terminal.screen.cells[y][left] in "╰└╚"
                   and terminal.screen.cells[y][right] in "╯┘╝"), None)
    if bottom is None:
        require(not required, "modal bottom border missing")
        return None
    return left, right, found["row"], bottom


def popup_text(terminal, title):
    bounds = rectangle(terminal, title, required=False)
    if bounds is None:
        return ""
    left, right, top, bottom = bounds
    return "\n".join("".join(terminal.screen.cells[y][left + 1:right]).rstrip()
                     for y in range(top + 1, bottom))


def path_line(terminal, title):
    return next((line.strip() for line in popup_text(terminal, title).splitlines() if line.strip().startswith("Path:")), "")


def modal_geometry_ready(terminal, title):
    bounds = rectangle(terminal, title, required=False)
    if bounds is None:
        return False
    left, right, top, bottom = bounds
    width, height = right - left + 1, bottom - top + 1
    # Empty/small listings intentionally shrink the popup. Its observed frame
    # must stay centered and bounded; callers separately require visible path,
    # caret and actions, rather than imposing the maximum height on every list.
    return (25 <= width <= min(terminal.columns - 2, 92)
            and 8 <= height <= min(terminal.rows - 2, 24)
            and left == (terminal.columns - width) // 2
            and top == (terminal.rows - height) // 2)


def open_popup(terminal, received=False):
    title = "Save attachment ·" if received else "Attach file ·"
    terminal.until(lambda: terminal.screen.locate(title) is not None
                   and terminal.screen.locate("[Cancel]") is not None
                   and "Path:" in popup_text(terminal, title))
    return title


def type_path(terminal, title, path, confirm=False):
    terminal.send(b"\x15" + str(path).encode())
    expected = Path(path).name or str(path)
    terminal.until(lambda: expected in path_line(terminal, title))
    if confirm:
        terminal.send(b"\r")


def draft(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        values = client.request("draft.list")["drafts"]
        require(len(values) == 1, "file dialog changed local draft identity/count")
        value = client.request("draft.read", draftId=values[0]["id"])
        require(client.request("cache.stats")["fixtureSends"] == 0, "file-dialog workflow sent mail")
        return value


def stable_draft(value):
    return {key: value.get(key) for key in ("id", "to", "cc", "bcc", "subject", "bodyText",
                                           "threadId", "inReplyTo", "attachments")}


def capture(terminal, directory, name):
    if directory is None:
        return
    terminal.gap(.06)
    value = screen_capture(terminal)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    (directory / f"{name}.txt").write_text("\n".join(value["currentCells"]) + "\n")
    width, height = terminal.columns * 9, terminal.rows * 18
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             '<rect width="100%" height="100%" fill="#111620"/>']

    def color(raw, fallback):
        return "#%02x%02x%02x" % tuple(raw[1:4]) if raw and raw[0] == "rgb" else fallback

    for y, begin, end, style in value["currentStyleRuns"]:
        foreground, background = color(style[0], "#e8ebf1"), color(style[1], "#111620")
        if len(style) > 5 and style[5]:
            foreground, background = background, foreground
        parts.append(f'<rect x="{begin * 9}" y="{y * 18}" width="{(end - begin) * 9}" height="18" fill="{background}"/>')
        for x in range(begin, end):
            cell = value["cellGrid"][y][x]
            if not cell or not cell.strip():
                continue
            weight = "bold" if style[2] else "normal"
            parts.append(f'<text x="{x * 9}" y="{y * 18 + 14}" font-family="monospace" font-size="14" font-weight="{weight}" fill="{foreground}">{html.escape(cell)}</text>')
    parts.append("</svg>")
    svg = directory / f"{name}.svg"
    svg.write_text("\n".join(parts))
    renderer = shutil.which("rsvg-convert")
    require(renderer is not None, "PNG capture needs the installed rsvg-convert renderer")
    subprocess.run([renderer, str(svg), "-o", str(directory / f"{name}.png")], check=True, timeout=15)


def start_ready(binary, directory, source):
    terminal = start(binary, directory, source, columns=160, rows=42)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "Fictional file-dialog message 096.")
                       and terminal.screen.mouse_tracking_mode == 1002)
        return terminal
    except Exception:
        terminal.close()
        raise


def assert_composer(terminal, count):
    terminal.until(lambda: terminal.screen.locate("Attach file ·") is None
                   and "Subject:" in terminal.text() and f"Attachments {count}" in terminal.text())


def attach_case(binary, directory, key, captures):
    source = fixture_setup(binary, directory)
    picks = directory / "choice files"
    nested = picks / "projects"
    nested.mkdir(mode=0o700, parents=True)
    (nested / "nested packet.txt").write_bytes(PAYLOADS["nested packet.txt"])
    second = picks / "qjk café notes.txt"
    second.write_bytes(PAYLOADS[second.name])
    (picks / ".hidden notes.txt").write_bytes(b"Hidden synthetic file.\n")
    (picks / "link.txt").symlink_to(second)
    for number in range(22):
        (picks / f"browse-{number:02}.txt").write_text("Fictional listing entry.\n")
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(key)
        terminal.until(lambda: "Subject:" in terminal.text() and "Attachments" in terminal.text())
        if key in (b"c", b"F"):
            terminal.send(b"irecipient@example.org\x1b")
            terminal.gap(.04)
        if key == b"c":
            terminal.send(b"\t\t\tiLaunch notes\tHi Maya, the notes are ready.\x1b")
            terminal.gap(.04)
        # Capture a committed baseline, not a stale title preceding autosave.
        # Review saves explicitly; Escape returns without submitting mail.
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "Sending account:" not in terminal.text() and "Subject:" in terminal.text())
        original = draft(binary, directory, source)
        base_count = len(original["attachments"])
        terminal.send(b"A")
        title = open_popup(terminal)
        terminal.send("qjk literal café.txt".encode())
        terminal.until(lambda: "qjk literal café.txt" in path_line(terminal, title))
        if key == b"c":
            for columns, rows in ((80, 24), (100, 30), (160, 42)):
                terminal.resize(columns, rows)
                terminal.until(lambda: modal_geometry_ready(terminal, title)
                               and "qjk literal café.txt" in path_line(terminal, title)
                               and "[Attach]" in popup_text(terminal, title)
                               and "[Cancel]" in popup_text(terminal, title))
                require("▏" in path_line(terminal, title), "resized dialog lost the visible caret")
                capture(terminal, captures, f"attach-{columns}x{rows}")
            left, right, top, _ = rectangle(terminal, title)
            typed = path_line(terminal, title)
            click(terminal, left + 5, top + 4)  # Blank modal row under the toolbar.
            click(terminal, 0, 0)  # Outside the modal.
            terminal.gap(.06)
            require(path_line(terminal, title) == typed, "blank/outside click changed typed attachment path")
        click(terminal, *point(terminal, "[Cancel]"))
        assert_composer(terminal, base_count)
        require(stable_draft(draft(binary, directory, source)) == stable_draft(original),
                "Cancel changed the originating draft or files")
        terminal.send(b"A")
        title = open_popup(terminal)
        type_path(terminal, title, picks, confirm=True)
        terminal.until(lambda: "projects/" in popup_text(terminal, title))
        require("link.txt" not in popup_text(terminal, title), "browser listed a symbolic link")
        if key == b"c":
            click(terminal, *point(terminal, "[Hidden off]"))
            terminal.until(lambda: ".hidden notes.txt" in popup_text(terminal, title))
            click(terminal, *point(terminal, "[Hidden on]"))
            terminal.until(lambda: ".hidden notes.txt" not in popup_text(terminal, title))
            old_path = path_line(terminal, title)
            left, right, top, _ = rectangle(terminal, title)
            report(terminal, left + 6, top + 7, button=65)
            terminal.until(lambda: path_line(terminal, title) != old_path)
            require(stable_draft(draft(binary, directory, source)) == stable_draft(original), "wheel attached a file")
            click(terminal, *point(terminal, "[Home]"))
            terminal.until(lambda: str(directory / "home") in popup_text(terminal, title))
            click(terminal, *point(terminal, "[Up]"))
            terminal.until(lambda: f"Folder: {directory}" in popup_text(terminal, title))
            type_path(terminal, title, picks, confirm=True)
            terminal.until(lambda: "projects/" in popup_text(terminal, title))
        click(terminal, *point(terminal, "projects/"))
        terminal.gap(.04)
        require(f"Folder: {picks}" in popup_text(terminal, title), "row selection navigated without confirmation")
        click(terminal, *point(terminal, "[Attach]"))
        terminal.until(lambda: "nested packet.txt" in popup_text(terminal, title))
        click(terminal, *point(terminal, "nested packet.txt"))
        terminal.gap(.04)
        require(len(draft(binary, directory, source)["attachments"]) == base_count, "file row click attached implicitly")
        capture(terminal, captures, f"{key.decode()}-selected-file")
        click(terminal, *point(terminal, "[Attach]"))
        assert_composer(terminal, base_count + 1)
        terminal.send(b"A")
        title = open_popup(terminal)
        type_path(terminal, title, picks / "qjk café")
        terminal.send(b"\x06")
        terminal.until(lambda: second.name in path_line(terminal, title))
        terminal.send(b"\r")
        assert_composer(terminal, base_count + 2)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        retained = draft(binary, directory, source)
        require(retained["id"] == original["id"], "multi-attachment workflow created another draft")
        require([item["filename"] for item in retained["attachments"][-2:]] == list(PAYLOADS),
                "mouse/Tab selected different outgoing files")
        for item in retained["attachments"][-2:]:
            raw = base64.urlsafe_b64decode(item["data"] + "=" * (-len(item["data"]) % 4))
            require(raw == PAYLOADS[item["filename"]], "attachment bytes changed through dialog/review")
        require(retained["to"] == original["to"] and retained["bodyText"] == original["bodyText"],
                "file dialog changed recipients/body")
        if key in (b"r", b"R"):
            require(retained["threadId"] == original["threadId"] and retained["inReplyTo"] == original["inReplyTo"],
                    "reply files lost threading")
        if key == b"F":
            require(retained["attachments"][:base_count] == original["attachments"], "forward lost original files")
            require(not retained["threadId"] and not retained["inReplyTo"], "forward acquired reply threading")
        return {"origin": key.decode(), "originalFiles": base_count, "addedFiles": 2,
                "literalUnicodeAndSpaces": True, "explicitMouseAttach": True,
                "cancelPreservesDraft": True, **terminal.finish()}
    except Exception as error:
        error.file_dialog_cells = screen_capture(terminal)
        capture(terminal, captures, f"{key.decode()}-failure")
        raise
    finally:
        terminal.close()


def save_case(binary, directory, captures, missing_downloads=False):
    source = fixture_setup(binary, directory)
    downloads = directory / "home/Downloads"
    if not missing_downloads:
        downloads.mkdir(mode=0o700)
    terminal = start_ready(binary, directory, source)
    try:
        underlying = terminal.screen.locate("Attachment 1:")
        terminal.send(b"Bs")
        title = open_popup(terminal, received=True)
        require("report.txt" in path_line(terminal, title), "Save lost the sanitized default filename")
        capture(terminal, captures, "save-missing-default" if missing_downloads else "save-default")
        if missing_downloads:
            require(not downloads.exists(), "opening Save created Downloads before confirmation")
            terminal.send(b"\x1b")
            terminal.until(lambda: terminal.screen.locate(title) is None and "Received attachments" in terminal.text())
            require(not downloads.exists(), "Cancel created Downloads")
            terminal.send(b"s")
            title = open_popup(terminal, received=True)
            terminal.send(b"\r")
            destination = downloads / "report.txt"
            terminal.until(lambda: destination.exists() and terminal.screen.locate(title) is None)
            require(destination.read_bytes() == FIRST, "default save changed file bytes")
            return {"downloadsDeferredUntilSave": True, "cancelCreatesNothing": True, **terminal.finish()}
        kept = downloads / "keep me.txt"
        kept.write_bytes(b"KEEP EXISTING CONTENT")
        destination = downloads / "received qjk café.txt"
        type_path(terminal, title, destination)
        typed = path_line(terminal, title)
        left, right, top, _ = rectangle(terminal, title)
        click(terminal, left + 5, top + 4)
        if underlying is not None:
            click(terminal, terminal.columns - 3, underlying["row"])
        else:
            click(terminal, terminal.columns - 2, 5)
        terminal.gap(.06)
        require(path_line(terminal, title) == typed, "modal click-through discarded the chosen Save path")
        type_path(terminal, title, kept, confirm=True)
        terminal.until(lambda: "already exists" in popup_text(terminal, title).lower())
        require(kept.read_bytes() == b"KEEP EXISTING CONTENT", "save overwrote an existing file")
        require(kept.name in path_line(terminal, title), "save failure lost the attempted path")
        capture(terminal, captures, "save-collision-retains-path")
        type_path(terminal, title, destination)
        click(terminal, *point(terminal, "[Save]"))
        terminal.until(lambda: destination.exists() and terminal.screen.locate(title) is None)
        require(destination.read_bytes() == FIRST, "Save targeted another attachment")
        require(destination.stat().st_mode & 0o077 == 0, "saved file lost owner-only permissions")
        terminal.send(b"Bjo")
        title = open_popup(terminal, received=True)
        terminal.until(lambda: "[Save & open]" in popup_text(terminal, title))
        opened = downloads / "received open.txt"
        type_path(terminal, title, opened)
        click(terminal, *point(terminal, "[Save & open]"))
        terminal.until(lambda: opened.exists() and "mock file-open validated" in terminal.text())
        require(opened.read_bytes() == SECOND, "Save & open targeted another received file")
        require(reader_contains(terminal.screen, "Fictional file-dialog message 096."), "Save changed originating reader")
        return {"noOverwrite": True, "failureRetainsPath": True, "modalClicksIsolated": True,
                "literalUnicodeSave": True, "saveAndOpenExplicit": True, **terminal.finish()}
    except Exception as error:
        error.file_dialog_cells = screen_capture(terminal)
        capture(terminal, captures, "missing-downloads-failure" if missing_downloads else "save-failure")
        raise
    finally:
        terminal.close()


def browser_case(binary, directory, captures):
    source = fixture_setup(binary, directory)
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(b"\r")
        terminal.until(lambda: "3/3" in terminal.text() and reader_contains(terminal.screen, "Fictional file-dialog message 096."))
        terminal.send(b"{{")
        terminal.until(lambda: "1/3 mails" in terminal.text())
        terminal.send(b"t")  # Earlier cards are initially folded.
        terminal.until(lambda: "1/3" in terminal.text() and reader_contains(terminal.screen, "Fictional file-dialog message 094."))
        capture(terminal, captures, "browser-focused-thread-card")
        terminal.send(b"o")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        require(reader_contains(terminal.screen, "Fictional file-dialog message 094."), "browser action moved the focused card")
        return {"focusedCard": "shared-msg-094", "mockBrowserCompleted": True,
                "targetIdCoveredByFrozenRequestUnit": True, **terminal.finish()}
    except Exception as error:
        error.file_dialog_cells = screen_capture(terminal)
        capture(terminal, captures, "browser-failure")
        raise
    finally:
        terminal.close()



def keyboard_case(binary, directory, captures):
    source = fixture_setup(binary, directory)
    picks = directory / "completion files"
    picks.mkdir(mode=0o700)
    (picks / "shared-one.txt").write_bytes(b"First fictional file.\n")
    (picks / "shared-two.txt").write_bytes(b"Second fictional file.\n")
    (picks / "README.md").write_bytes(b"Case-insensitive fixture.\n")
    (directory / "home").mkdir(mode=0o700, exist_ok=True)
    (directory / "home/.hidden-test.txt").write_bytes(b"Hidden fictional file.\n")
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Attachments" in terminal.text())
        terminal.send(b"A")
        title = open_popup(terminal)
        # The first Tab returns this exact prefix unchanged: it used to crash
        # when Field.set copied its own borrowed buffer using @memcpy.
        type_path(terminal, title, picks / "shared-")
        type_path(terminal, title, picks / "rea")
        terminal.send(b"\x06")
        terminal.until(lambda: "README.md" in path_line(terminal, title))
        type_path(terminal, title, picks / "shared-")
        terminal.send(b"\x06\x06")
        terminal.until(lambda: "shared-one.txt" in path_line(terminal, title))
        terminal.send(b"\x06")
        terminal.until(lambda: "shared-two.txt" in path_line(terminal, title))
        type_path(terminal, title, picks / "shared-")  # Restore both matches.
        terminal.send(b"\x0e")  # Ctrl+N: next entry, no arrow key required.
        terminal.until(lambda: "shared-two.txt" in path_line(terminal, title))
        terminal.send(b"\x10")  # Ctrl+P: previous entry.
        terminal.until(lambda: "shared-one.txt" in path_line(terminal, title))
        terminal.send(b"\x0f")  # Ctrl+O: parent folder.
        terminal.until(lambda: f"Folder: {directory}" in popup_text(terminal, title)
                       and "shared-one.txt" not in path_line(terminal, title))
        terminal.send(b"\x07")  # Ctrl+G: HOME directory.
        terminal.until(lambda: f"Folder: {directory / 'home'}" in popup_text(terminal, title))
        terminal.send(b"\x14")  # Ctrl+T toggles hidden entries.
        terminal.until(lambda: "[Hidden on]" in popup_text(terminal, title)
                       and ".hidden-test.txt" in popup_text(terminal, title))
        require("[Up] Ctrl+O" in popup_text(terminal, title)
                and "[Home] Ctrl+G" in popup_text(terminal, title),
                "keyboard folder shortcuts are not discoverable")
        capture(terminal, captures, "keyboard-folder-controls")
        terminal.send(b"\x1b")
        terminal.until(lambda: title not in terminal.text() and "Subject:" in terminal.text())
        return {"unchangedCompletionPrefix": True, "tabAndShiftTab": True,
                "keyboardUpHomeHidden": True, **terminal.finish()}
    except Exception as error:
        error.file_dialog_cells = screen_capture(terminal)
        capture(terminal, captures, "keyboard-failure")
        raise
    finally:
        terminal.close()


def tab_buttons_case(binary, directory, captures):
    source = fixture_setup(binary, directory)
    home = directory / "home"
    home.mkdir(mode=0o700, exist_ok=True)
    files = directory / "button files"
    files.mkdir(mode=0o700)
    first = files / "first report.txt"
    second = files / "second report.txt"
    first.write_bytes(b"Keep these exact first bytes.\n")
    second.write_bytes(b"Remove these second bytes.\n")
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text())
        terminal.send(b"irecipient@example.org")
        terminal.gap(.04)
        terminal.send(b"\x1b")
        terminal.gap(.04)  # A legacy Escape prefix must not become Alt+Tab.
        terminal.send(b"\t\t\t\ti")
        terminal.until(lambda: "Body: INSERT" in terminal.text())
        terminal.send(b"Keep this body.")
        terminal.until(lambda: "Keep this body." in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.04)
        for number, path in enumerate((first, second), 1):
            terminal.send(b"A")
            title = open_popup(terminal)
            type_path(terminal, title, path, confirm=True)
            assert_composer(terminal, number)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        terminal.send(b"\x1b")
        assert_composer(terminal, 2)
        original = draft(binary, directory, source)
        terminal.send(b"\t")  # Body -> Add button.
        terminal.until(lambda: "Buttons" in terminal.text() and "Enter Activate" in terminal.text())
        terminal.send(b"\r")
        title = open_popup(terminal)
        # Path -> Up -> Home -> Hidden -> Listing -> Attach -> Cancel.
        terminal.send(b"\t\t\r")
        terminal.until(lambda: f"Folder: {home}" in popup_text(terminal, title))
        terminal.send(b"\t\r")
        terminal.until(lambda: "[Hidden on]" in popup_text(terminal, title))
        terminal.send(b"\t\t\t\r")
        assert_composer(terminal, 2)
        terminal.send(b"\t\t\r")  # Add -> first[x] -> second[x] -> remove.
        assert_composer(terminal, 1)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        retained = draft(binary, directory, source)
        require(retained["id"] == original["id"], "button focus changed draft identity")
        require([v["filename"] for v in retained["attachments"]] == [first.name],
                "Tab/Enter removed another attachment")
        raw = retained["attachments"][0]["data"]
        require(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)) == first.read_bytes(),
                "button removal changed the remaining file bytes")
        require(retained["to"] == original["to"] and retained["bodyText"] == original["bodyText"],
                "button navigation changed recipients or body")
        terminal.send(b"\x1b")
        assert_composer(terminal, 1)
        terminal.send(b"\x1b[Z\x1b[Z")  # first[x] -> Add -> Body.
        terminal.until(lambda: "Enter Activate" not in terminal.text())
        terminal.send(b"\t\t")
        terminal.until(lambda: "Enter Activate" in terminal.text())
        capture(terminal, captures, "focused-remove-button")
        terminal.send(b"x")
        assert_composer(terminal, 0)
        return {"tabAddAndEveryRemove": True, "fileDialogButtonsViaTab": True,
                "shiftTabRestoresBody": True, "exactRemainingBytes": True, **terminal.finish()}
    except Exception as error:
        error.file_dialog_cells = screen_capture(terminal)
        capture(terminal, captures, "tab-buttons-failure")
        raise
    finally:
        terminal.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"syntheticOnly": True, "desktopUsed": False, "liveWrites": False, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-file-dialog-") as temporary:
        for name in CASES:
            if args.case and name not in args.case:
                continue
            directory = Path(temporary) / name
            begun = time.monotonic()
            try:
                if name.startswith("attach-"):
                    key = {"attach-new": b"c", "attach-reply": b"r", "attach-all": b"R", "attach-forward": b"F"}[name]
                    result = attach_case(binary, directory, key, args.capture_dir)
                elif name == "browser-thread":
                    result = browser_case(binary, directory, args.capture_dir)
                elif name == "keyboard":
                    result = keyboard_case(binary, directory, args.capture_dir)
                elif name == "tab-buttons":
                    result = tab_buttons_case(binary, directory, args.capture_dir)
                else:
                    result = save_case(binary, directory, args.capture_dir, name == "missing-downloads")
                item = {"name": name, "passed": True, **result}
            except Exception as error:
                item = {"name": name, "passed": False, "error": f"{type(error).__name__}: {error}",
                        "traceback": traceback.format_exc()}
                if hasattr(error, "file_dialog_cells"):
                    item["diagnostics"] = error.file_dialog_cells
            item["elapsedSeconds"] = round(time.monotonic() - begun, 3)
            receipt["cases"].append(item)
            print(json.dumps({key: value for key, value in item.items() if key != "diagnostics"}, ensure_ascii=False), flush=True)
            if not item["passed"]:
                break
    receipt["passed"] = bool(receipt["cases"]) and all(case["passed"] for case in receipt["cases"])
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
