#!/usr/bin/env python3
"""Small local account/help checks in owned PTYs; no desktop or live mail."""
import argparse
import json
from pathlib import Path
import sys
import tempfile

from terminal_integration import Client, require
from terminal_html import screen_capture
from terminal_mouse import click
from terminal_mouse_screen import MouseScreen
from terminal_repaint import BuiltinTerminal, panel_interiors


ACCOUNTS = ("alex.demo@long-company.example",
            "morgan.example@long-company-exampl.example",
            "optional@example.com")


def setup(directory):
    directory.mkdir(parents=True)
    path = directory / "fictional-config.json"
    path.write_text(json.dumps({"oauthClientFile": "", "chrome": "/nonexistent/fictional-browser",
        "chromeUserData": "", "accounts": [
            {"address": account, "profile": f"Fictional profile {index}", "enabled": True, "required": False}
            for index, account in enumerate(ACCOUNTS)]}) + "\n")
    path.chmod(0o600)
    return path


def navigation(terminal):
    title = terminal.screen.locate("Accounts / mailboxes")
    require(title is not None, "account pane absent")
    area = next((rect for rect in panel_interiors(terminal.screen)
                 if rect[0] <= title["column"] < rect[1] and rect[2] - 1 == title["row"]), None)
    require(area is not None, "account frame absent")
    left, right, top, bottom = area
    rows = [(y, "".join(terminal.screen.cells[y][left:right]).strip()) for y in range(top, bottom)]
    begin = next(y for y, text in rows if text == "ACCOUNTS")
    end = next(y for y, text in rows if text == "MAILBOXES")
    return left, right, [(y, text.removeprefix(">").strip()) for y, text in rows if begin < y < end]


def capture(terminal, directory, name):
    if directory is not None:
        terminal.gap(.12)  # Drain the complete frame before taking a cell snapshot.
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{name}.json").write_text(json.dumps(screen_capture(terminal)) + "\n")


def account_case(binary, directory, config, capture_dir=None):
    terminal = BuiltinTerminal(binary, directory, config, account=ACCOUNTS[0], screen_type=MouseScreen)
    try:
        terminal.until(lambda: terminal.screen.locate("Contacts") is not None)
        terminal.until(lambda: terminal.screen.mouse_tracking_mode == 1002)
        left, right, rows = navigation(terminal)
        starts = []
        for address in ACCOUNTS:
            starts.append(next(y for y, text in rows if text.startswith(address[:8])))
        require(starts[1] == starts[0] + 1, "exact-width account introduced a blank continuation row")
        require(starts[2] > starts[1] + 1, "long fictional account did not wrap")
        for index, address in enumerate(ACCOUNTS):
            stop = starts[index + 1] if index + 1 < len(starts) else rows[-1][0]
            content = [(y, text) for y, text in rows if starts[index] <= y < stop]
            require(content and all(text for _, text in content), "blank row inside account identity")
            require("".join(text for _, text in content) == address, "account address clipped or overlapped")
        require(rows[-1][1] == "" and rows[-2][1] != "", "mailbox separator should occupy exactly one row")
        capture(terminal, capture_dir, "accounts-wide")
        # Continuation rows have the same account target as the first row.
        long_end = starts[2] - 1
        click(terminal, left + 3, long_end)
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0])
        _, _, selected = navigation(terminal)
        require(next(text for y, text in selected if y == long_end) != "", "click erased continuation text")
        click(terminal, left + 3, starts[2])
        terminal.until(lambda: ACCOUNTS[2] in terminal.screen.lines()[0])
        terminal.finish()
        print("PASS account wrap: exact-width rows, long identity, continuation click")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def visible_section(terminal, literal):
    for _ in range(160):
        if terminal.screen.locate(literal) is not None:
            return
        terminal.send(b"j")
        terminal.gap(.015)
    raise AssertionError(f"help content unreachable: {literal}")


def help_case(binary, directory, config, capture_dir=None):
    terminal = BuiltinTerminal(binary, directory, config, account=ACCOUNTS[0], screen_type=MouseScreen)
    try:
        terminal.until(lambda: terminal.screen.locate("Contacts") is not None)
        terminal.send(b"?")
        terminal.until(lambda: terminal.screen.locate("NAVIGATION") is not None)
        # At wide sizes section headings and key/action columns are distinct.
        heading = terminal.screen.locate("NAVIGATION")
        require(terminal.screen.styles[heading["row"]][heading["column"]][2], "help section heading is not emphasized")
        action_columns = []
        for keys, action in (("j / k · arrows", "Move through the focused pane"),
                             ("h / l · Tab", "Change pane; Shift+Tab goes back"),
                             ("Enter", "Open mail or choose the focused item")):
            key_at, action_at = terminal.screen.locate(keys), terminal.screen.locate(action)
            require(key_at is not None and action_at is not None and key_at["row"] == action_at["row"],
                    "wide help key/action row is not aligned")
            require(action_at["column"] > key_at["column"] + len(keys), "help action overlaps its key")
            action_columns.append(action_at["column"])
        require(len(set(action_columns)) == 1, "help action column is ragged")
        capture(terminal, capture_dir, "help-wide")
        for literal in ("SEARCH & READING", "MAIL ACTIONS", "CONTACTS", "COMPOSE & SEND", "$EDITOR", "Ctrl+S / :send"):
            visible_section(terminal, literal)
        terminal.send(b"\x1b[H")
        terminal.until(lambda: terminal.screen.locate("NAVIGATION") is not None)
        # Small terminals must wrap the same instructions instead of clipping.
        terminal.resize(48, 20)
        terminal.until(lambda: terminal.screen.locate("NAVIGATION") is not None)
        capture(terminal, capture_dir, "help-narrow")
        for literal in ("SEARCH & READING", "MAIL ACTIONS", "CONTACTS", "COMPOSE & SEND", "$EDITOR", "Ctrl+S / :send"):
            visible_section(terminal, literal)
        terminal.send(b"\x1b[F")
        terminal.gap(.1)
        require("Back" in terminal.text() or "Return" in terminal.text(), "help back hint lost at narrow tail")
        terminal.send(b"q")
        terminal.until(lambda: terminal.screen.locate("NAVIGATION") is None)
        require(terminal.process.poll() is None, "q from help exited the TUI")
        terminal.finish()
        print("PASS help: styled sections, wide/narrow complete scrolling, q returns")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, help="Optional synthetic current-cell snapshots for visual review")
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary absent")
    with tempfile.TemporaryDirectory(prefix="omagma-local-ui-") as temporary:
        directory = Path(temporary) / "accounts"
        config = setup(directory)
        account_case(binary, directory, config, args.capture_dir)
        help_directory = Path(temporary) / "help"
        help_config = setup(help_directory)
        help_case(binary, help_directory, help_config, args.capture_dir)
        for root, cfg in ((directory, config), (help_directory, help_config)):
            with Client(binary, root, fixtures=False, extra=("--fixtures", "--config", str(cfg))) as client:
                for account in ACCOUNTS:
                    require(client.request("cache.stats", account, cacheOnly=True)["fixtureSends"] == 0,
                            "local UI check submitted mail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
