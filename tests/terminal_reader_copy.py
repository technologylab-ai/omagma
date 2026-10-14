#!/usr/bin/env python3
"""Received-text selection/OSC52 in owned fictional PTYs, never a desktop.

CASES and the module-local MouseTerminal factory also work in Darwin guardian
sessions. Runtime suites require the coordinator's cooperative host window.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import re
import sys
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal as OwnedMouseTerminal, click, report
from terminal_reader import reader_contains
from terminal_reader_editor import ReaderScreen, payload, private_json

MouseTerminal = OwnedMouseTerminal
if sys.platform == "darwin":
    from terminal_macos import DarwinTerminal

    # The shared workflow runner may already have installed the guardian.
    if not issubclass(OwnedMouseTerminal, DarwinTerminal):
        class GuardianMouseTerminal(DarwinTerminal, OwnedMouseTerminal):
            pass

        MouseTerminal = GuardianMouseTerminal

ACCOUNT = "personal@example.com"
MESSAGE = "reader-copy-first"
SECOND = "reader-copy-second"
UNICODE = "café e\u0301 👩\u200d💻 東京"
PARAGRAPH = "This paragraph wraps across display rows while keeping its logical words and spaces for agent chats."
BODY = "Alpha " + UNICODE + " start.\n\n" + PARAGRAPH + "\n\nTail last word.\n> A folded quotation must stay excluded.\n"
SECOND_BODY = "Second copy fixture body belongs to another received message.\n"
HTML = ("<h2>Rich received fixture</h2><p><strong>Alpha café</strong> and "
        "<em>readable HTML</em> 👩‍💻 東京.</p><ul><li>First rich item</li><li>Second rich item</li></ul>"
        "<table><tr><th>Key</th><th>Value</th></tr><tr><td>Launch</td><td>Ready</td></tr></table>"
        '<p><a href="https://example.test/review?tracking=abcdefghijklmnopqrstuv01234567890123456789">Review notes</a></p>')
OSC52 = re.compile(rb"\x1b\]52;[a-z]*;([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)")


def clips(terminal):
    # Never relay raw OSC52 escapes to the harness host's terminal.
    return [base64.b64decode(match).decode("utf-8") for match in OSC52.findall(bytes(terminal.output))]


def prepare(binary, directory, rich=False):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = directory.resolve()
    corpus = directory / "fixture"
    accounts = corpus / "accounts"
    accounts.mkdir(mode=0o700, parents=True)
    first = payload(MESSAGE, "Fictional copy fixture", BODY, 1780871400000)
    if rich:
        first["payload"]["mimeType"] = "text/html"
        for header in first["payload"]["headers"]:
            if header["name"].lower() == "content-type":
                header["value"] = "text/html; charset=utf-8"
        data = HTML.encode()
        first["payload"]["body"] = {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}
    private_json(accounts / "personal.json", {"account": ACCOUNT,
        "messages": [first, payload(SECOND, "Other received copy fixture", SECOND_BODY, 1780871300000)],
        "sync": {"historyId": "100"}})
    config = directory / "fictional-config.json"
    private_json(config, {"oauthClientFile": "", "chrome": "/nonexistent/fictional-browser",
        "chromeUserData": "", "accounts": [{"address": ACCOUNT, "profile": "Profile 1", "enabled": True, "required": True}]})
    extra = ("--fixture-root", str(corpus), "--config", str(config), "--prefetch-bodies", "0")
    with Client(binary, directory, extra=extra) as client:
        client.request("mail.list", limit=2, label="INBOX")
        first_body = client.request("mail.read", messageId=MESSAGE)
        client.request("mail.read", messageId=SECOND)
    return directory, extra, first_body


def baseline(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        return {"body": client.request("mail.read", messageId=MESSAGE, cacheOnly=True),
                "drafts": client.request("draft.list")["drafts"],
                "operations": client.request("operation.list")["operations"],
                "sends": client.request("cache.stats")["fixtureSends"]}


def ready(terminal, text="Alpha"):
    return (not terminal.screen.frame_open and reader_contains(terminal.screen, text)
            and "Fetching" not in terminal.text())


def start(binary, directory, extra, text="Alpha", columns=160, rows=42, environment=None, no_mouse=False):
    terminal = MouseTerminal(binary, directory, extra=(*extra, *(("--no-mouse",) if no_mouse else ())),
        columns=columns, rows=rows, screen_type=ReaderScreen,
        environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0", **(environment or {})})
    terminal.until(lambda: ready(terminal, text))
    terminal.send(b"\r")
    terminal.until(lambda: ready(terminal, text) and "V Select" in terminal.text())
    return terminal


def visual(terminal, keys=b"VV"):
    terminal.send(keys)
    terminal.until(lambda: not terminal.screen.frame_open and "[Copy y]" in terminal.text()
                   and "[Cancel Esc]" in terminal.text())


def copied(terminal, keys=b"y", count=1):
    previous_frame = terminal.screen.completed_frames
    terminal.send(keys)
    terminal.until(lambda: len(clips(terminal)) == count and not terminal.screen.frame_open
                   and terminal.screen.completed_frames > previous_frame
                   and "terminal clipboard" in terminal.text() and "[Copy y]" not in terminal.text())
    return clips(terminal)[-1]


def capture(terminal, capture_dir, name):
    if capture_dir is None:
        return
    from terminal_html import screen_capture
    capture_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_json(capture_dir / (name + ".json"), {"syntheticOnly": True, **screen_capture(terminal)})


def keyboard_case(binary, directory, capture_dir=None):
    directory, extra, message = prepare(binary, directory)
    saved = baseline(binary, directory, extra)
    terminal = start(binary, directory, extra)
    try:
        terminal.send(b"y")
        terminal.until(lambda: "V selects text" in terminal.text())
        require(not clips(terminal), "normal y overwrote the clipboard")
        visual(terminal)
        require(copied(terminal, b"ey") == "Alpha", "word-end yank included headers, padding or another grapheme")
        visual(terminal)
        terminal.send(b"dxcspuUro")  # Vim operator letters must not mutate/compose/open Gmail.
        terminal.until(lambda: "[Copy y]" in terminal.text())
        require(not any(word in terminal.text() for word in ("Review send", "Compose ·", "Move selected mail")),
                "Visual operator keys invoked a mail mutation/composer")
        terminal.send(b"o")  # Restore swapped endpoints; selection is still the first character.
        terminal.send(b"\x1b")
        terminal.until(lambda: "[Copy y]" not in terminal.text())
        visual(terminal, b"VVV")
        terminal.until(lambda: "LINE" in terminal.text() and "V Chars" in terminal.text())
        first_line = copied(terminal, count=2)
        require(first_line == BODY.splitlines()[0] + "\n", "line mode did not copy a Unicode logical line exactly")
        visual(terminal)
        # gg/G and $ operate only on this message's body, never the pane chrome.
        terminal.send(b"ggG$")
        all_body = copied(terminal, count=3)
        require(all_body.startswith("Alpha " + UNICODE) and PARAGRAPH in all_body and "Tail last word." in all_body,
                "body navigation or soft-wrap joins lost received content")
        require("From:" not in all_body and "Labels:" not in all_body and "Copy y" not in all_body,
                "Visual copied envelope or UI controls")
        terminal.send(b":copy-message\r")
        terminal.until(lambda: len(clips(terminal)) == 4)
        snapshot = clips(terminal)[-1]
        require("From:" in snapshot and "Subject: Fictional copy fixture" in snapshot and BODY in snapshot,
                "explicit whole-message copy lost envelope/full plaintext")
        require(baseline(binary, directory, extra) == saved, "read-only copy changed cached mail, drafts, operations or sends")
        capture(terminal, capture_dir, "reader-copy-keyboard")
        terminal.finish()
        return {"normalYIsHint": True, "wordAndUnicodeLineExact": True, "softWrapsJoined": True,
                "operatorsDoNotWrite": True, "explicitSnapshot": True, "osc52Writes": 4}
    except Exception:
        capture(terminal, capture_dir, "reader-copy-keyboard-failure")
        raise
    finally:
        terminal.close()


def paragraph_position_case(binary, directory, capture_dir=None):
    directory, extra, _ = prepare(binary, directory)
    saved = baseline(binary, directory, extra)
    terminal = start(binary, directory, extra)
    try:
        alpha = terminal.screen.locate("Alpha")
        original_style = terminal.screen.styles[alpha["row"]][alpha["column"]]
        terminal.send(b"V")
        terminal.until(lambda: not terminal.screen.frame_open and "[Select V]" in terminal.text()
                       and "MOVE" in terminal.text())
        caret_style = terminal.screen.styles[alpha["row"]][alpha["column"]]
        require(caret_style != original_style, "MOVE has no visible themed caret")
        terminal.send(b"jj0")
        def at_paragraph():
            point = terminal.screen.locate("This paragraph")
            return (point is not None and not terminal.screen.frame_open
                    and terminal.screen.styles[point["row"]][point["column"]] == caret_style)
        terminal.until(at_paragraph)
        require(terminal.screen.styles[alpha["row"]][alpha["column"]] == original_style,
                "moving to a paragraph left the earlier text selected")
        terminal.send(b"y")
        terminal.until(lambda: "Move to the starting point" in terminal.text())
        require(not clips(terminal), "an unmarked cursor copied text")
        terminal.send(b"\t\r")  # Select button marks the chosen start.
        terminal.until(lambda: "[Copy y]" in terminal.text() and "CHAR" in terminal.text())
        terminal.send(b"V")
        terminal.until(lambda: not terminal.screen.frame_open and "LINE" in terminal.text()
                       and "V Chars" in terminal.text())
        terminal.send(b"V")
        terminal.until(lambda: not terminal.screen.frame_open and "CHAR" in terminal.text()
                       and "V Line" in terminal.text())
        require(copied(terminal, b"$y") == PARAGRAPH, "keyboard copied text outside the chosen paragraph")
        terminal.send(b"V")
        terminal.until(lambda: "[Select V]" in terminal.text())
        terminal.send(b"jj0w ")  # Move to paragraph's second word, Space marks.
        terminal.until(lambda: "[Copy y]" in terminal.text() and "CHAR" in terminal.text())
        require(copied(terminal, b"ey", count=2) == "paragraph",
                "keyboard could not copy an interior word from a chosen start")
        require(baseline(binary, directory, extra) == saved, "positioning or copying mutated mail")
        capture(terminal, capture_dir, "reader-copy-chosen-paragraph")
        terminal.finish()
        return {"unmarkedCaret": True, "selectedMiddleParagraphExact": True,
                "selectedInteriorWordExact": True, "modeSwitchesVisible": True,
                "selectButtonKeyboardReachable": True, "noWrites": True}
    finally:
        terminal.close()


def mouse_theme_case(binary, directory, capture_dir=None):
    directory, extra, _ = prepare(binary, directory)
    colors = directory / "state/omarchy/current/theme/colors.toml"
    colors.parent.mkdir(mode=0o700, parents=True)
    colors.write_text('background = "#102030"\nforeground = "#c6ffee"\naccent = "#ffaa22"\nselection = "#334455"\n')
    terminal = start(binary, directory, extra)
    try:
        point = terminal.screen.locate("Alpha")
        require(point is not None, "body mouse target absent")
        x, row = point["column"], point["row"]
        click(terminal, x, row)
        terminal.gap(.04)
        require("[Copy y]" not in terminal.text() and not clips(terminal), "plain reader click selected/copied")
        report(terminal, x, row)
        report(terminal, x + 4, row, button=32)
        report(terminal, x + 4, row, release=True)
        terminal.until(lambda: "[Copy y]" in terminal.text() and not terminal.screen.frame_open)
        require(not clips(terminal), "mouse release changed the clipboard without explicit Copy")
        actual = terminal.screen.locate("Alpha")
        require(terminal.screen.styles[actual["row"]][actual["column"]][1] == ("rgb", 51, 68, 85),
                "selection did not use active theme selection color")
        require(terminal.screen.styles[actual["row"]][actual["column"] + 4][1] == ("rgb", 255, 170, 34),
                "selection cursor did not use active theme accent")
        colors.write_text('background = "#102030"\nforeground = "#c6ffee"\naccent = "#22ddcc"\nselection = "#445566"\n')
        terminal.send(b"\x0c")
        terminal.until(lambda: terminal.screen.styles[actual["row"]][actual["column"]][1] == ("rgb", 68, 85, 102))
        require("[Copy y]" in terminal.text(), "theme-only reload discarded valid text selection")
        require(copied(terminal) == "Alpha", "mouse-selected copy included padding or split Unicode")
        # Copy is also discoverable and reachable through the action palette.
        terminal.send(b"\x10Copy message\t\r")
        terminal.until(lambda: len(clips(terminal)) == 2)
        require("Subject: Fictional copy fixture" in clips(terminal)[-1], "palette copy did not use the guarded snapshot operation")
        capture(terminal, capture_dir, "reader-copy-theme")
        terminal.finish()
        return {"clickUnchanged": True, "dragReleaseNoClipboard": True, "themeSelectionAndCursor": True,
                "themeReloadRetainsSelection": True, "paletteCopy": True}
    finally:
        terminal.close()


def rich_resize_case(binary, directory, capture_dir=None):
    directory, extra, _ = prepare(binary, directory, rich=True)
    terminal = start(binary, directory, extra, text="Rich received fixture")
    try:
        visual(terminal)
        terminal.send(b"ggG$")
        rendered = copied(terminal)
        require("Rich received fixture" in rendered and "Alpha café" in rendered and "First rich item" in rendered,
                "HTML body projection omitted styled received content")
        require("Key" in rendered and "Launch" in rendered and "Ready" in rendered and "Review notes" in rendered,
                "HTML table/link display projection lost semantic text")
        require("<p>" not in rendered and "<table>" not in rendered and "From:" not in rendered,
                "HTML visual copy used source or envelope instead of rendered body")
        visual(terminal)
        terminal.send(b"w")
        terminal.resize(110, 28)
        terminal.until(lambda: not terminal.screen.frame_open and "Rich received fixture" in terminal.text())
        # Width-sensitive table projection may be ambiguous: clearing is safe.
        if "[Copy y]" in terminal.text():
            value = copied(terminal, count=2)
            require(value and "From:" not in value and "<" not in value, "resize reanchor copied stale/header/source text")
        else:
            require("Selection cleared" in terminal.text(), "ambiguous resize lost selection silently")
            require(len(clips(terminal)) == 1, "resize auto-copied to clipboard")
        capture(terminal, capture_dir, "reader-copy-rich")
        terminal.finish()
        return {"renderedHtmlOnly": True, "tableAndLinkProjection": True, "resizeReanchorsOrClearsSafely": True}
    finally:
        terminal.close()


def narrow_mono_source_case(binary, directory, capture_dir=None):
    directory, extra, _ = prepare(binary, directory)
    terminal = start(binary, directory, extra, columns=100, rows=18, environment={"NO_COLOR": "1"})
    try:
        visual(terminal)
        terminal.send(b"e")
        terminal.until(lambda: "[Copy y]" in terminal.text())
        require(any(7 in [int(value) for value in sequence.split(b";") if value.isdigit()]
                    for sequence in re.findall(rb"\x1b\[([0-9;]*)m", bytes(terminal.output))),
                "NO_COLOR selection lacks reverse video")
        require(copied(terminal) == "Alpha", "narrow monochrome copy changed selected text")
        visual(terminal)
        terminal.send(b"\x1b")
        terminal.until(lambda: "[Copy y]" not in terminal.text())
        # A deliberate next-mail key clears selection before navigating.
        visual(terminal)
        terminal.send(b"J")
        terminal.until(lambda: ready(terminal, SECOND_BODY.strip()) and "[Copy y]" not in terminal.text())
        terminal.send(b"y")
        terminal.until(lambda: "V selects text" in terminal.text())
        require(len(clips(terminal)) == 1, "mail change allowed stale first-message copy")
        capture(terminal, capture_dir, "reader-copy-mono")
        terminal.finish()
    finally:
        terminal.close()
    # Another fresh PTY explicitly delegates mouse selection to the terminal.
    disabled = directory / "no-mouse"
    disabled, disabled_extra, _ = prepare(binary, disabled)
    terminal = start(binary, disabled, disabled_extra, no_mouse=True)
    try:
        require(not terminal.screen.mouse_modes, "--no-mouse enabled app mouse tracking")
        point = terminal.screen.locate("Alpha")
        report(terminal, point["column"], point["row"])
        report(terminal, point["column"] + 4, point["row"], button=32)
        report(terminal, point["column"] + 4, point["row"], release=True)
        terminal.gap(.04)
        require("[Copy y]" not in terminal.text() and not clips(terminal), "--no-mouse gesture selected/copied")
        terminal.finish()
    finally:
        terminal.close()
    return {"narrowMonoExact": True, "sourceChangeClearsSelection": True, "noMouseBypass": True}


CASES = (("reader-copy-keyboard", keyboard_case), ("reader-copy-paragraph-position", paragraph_position_case),
         ("reader-copy-mouse-theme", mouse_theme_case),
         ("reader-copy-rich-resize", rich_resize_case), ("reader-copy-narrow-mono-source", narrow_mono_source_case))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--build-mode", type=build_mode)
    parser.add_argument("--case", action="append", choices=[name for name, _ in CASES])
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if args.output:
        require(not args.output.exists(), "preserve previous reader-copy receipt")
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    result = {**read_build_info(binary, args.build_mode), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "platform": sys.platform, "architecture": platform.machine(), "syntheticOnly": True,
              "desktopUsed": False, "liveWrites": False, "guardianTty": sys.platform == "darwin", "passed": False, "cases": []}
    selected = set(args.case or [name for name, _ in CASES])
    with tempfile.TemporaryDirectory(prefix="omagma-reader-copy-") as temporary:
        root = Path(temporary).resolve()
        for name, case in CASES:
            if name not in selected:
                continue
            entry = {"name": name, "passed": False}
            began = time.monotonic()
            try:
                entry.update(case(binary, root / name, args.capture_dir))
                entry["passed"] = True
            except Exception as error:
                entry["error"] = f"{type(error).__name__}: {error}"
            entry["elapsedSeconds"] = round(time.monotonic() - began, 4)
            result["cases"].append(entry)
            if args.output:
                private_json(args.output, result)
            print(json.dumps(entry), flush=True)
            if not entry["passed"]:
                return 1
    result["passed"] = len(result["cases"]) == len(selected)
    if args.output:
        private_json(args.output, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
