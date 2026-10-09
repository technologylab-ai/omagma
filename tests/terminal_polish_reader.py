#!/usr/bin/env python3
"""Focused reader navigation/search/wrapping polish in synthetic owned PTYs."""
import argparse
import base64
from pathlib import Path
import sys
import tempfile

from terminal_integration import ACCOUNTS, Client, require
from terminal_reader import reader_contains, reader_rows
from terminal_scroll_progress import fixture, options, seed, start, contains


def setup(binary, directory):
    source = fixture(directory)
    for account in ACCOUNTS:
        messages = source.data[account]["baseline"]["messages"]
        for message in messages:
            number = int(message["id"].rsplit("-", 1)[1])
            text = (f"Scroll fixture {account} body {number:03}.\nHi Alex,\n\n"
                    "The onboarding instructions are ready for this preview build.\n"
                    "A second readable paragraph explains the next steps.\n"
                    "On Monday Alex wrote:\n> Old quoted history has several words.\n-- \nA fictional signature\n")
            message["payload"]["body"] = {"size": len(text.encode()), "data": base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")}
        source.stage(account, "baseline")
    seed(binary, directory, source, 96)
    with Client(binary, directory, extra=options(source, 96)) as client:
        for number in (93, 94, 95):
            client.request("mail.read", ACCOUNTS[0], messageId=f"shared-msg-{number:03}")
        client.request("mail.thread", ACCOUNTS[0], threadId="shared-thread-031")
    return source


def finish(terminal):
    terminal.finish()


def navigation(binary, directory):
    source = setup(binary, directory)
    terminal = start(binary, directory, source, 96)
    try:
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_tracking_mode == 1002)
        terminal.send(b"GlJ")
        terminal.until(lambda: contains(terminal, 64))
        # K must reach65 without changing focus back to the list.
        terminal.send(b"K")
        terminal.until(lambda: contains(terminal, 65))
        terminal.send(b"J")
        terminal.until(lambda: contains(terminal, 64))
        finish(terminal)
        print("PASS reader polish: J/K cross both32-row boundaries with reader focus")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def search_return(binary, directory):
    source = setup(binary, directory)
    terminal = start(binary, directory, source, 96)
    try:
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_tracking_mode == 1002)
        terminal.send(b"jjj")
        terminal.until(lambda: contains(terminal, 93))
        for prefix, scope in ((b"/", "Cache search"), (b"\\", "Gmail search")):
            terminal.send(prefix + b'096\r')
            terminal.until(lambda: scope in terminal.screen.lines()[0] and contains(terminal, 96))
            terminal.send(b"q")
            terminal.until(lambda: scope not in terminal.screen.lines()[0] and contains(terminal, 93))
        finish(terminal)
        print("PASS reader polish: q restores middle selected ID after cache and Gmail searches")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def compact(binary, directory):
    source = setup(binary, directory)
    terminal = start(binary, directory, source, 96)
    try:
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_tracking_mode == 1002)
        terminal.send(b"\r")
        terminal.until(lambda: "3/3" in terminal.text() and contains(terminal, 96))
        terminal.send(b"Q")
        terminal.until(lambda: "Quoted history folded" in terminal.text())
        require(contains(terminal, 96), "Q lost focused thread card")
        terminal.send(b"S")
        terminal.until(lambda: "Signature folded" in terminal.text())
        require(contains(terminal, 96), "S lost focused thread card")
        terminal.resize(80, 24)
        terminal.send(b"v")
        terminal.until(lambda: reader_contains(terminal.screen, "Hi Alex,"))
        terminal.gap(.08)
        rows = [text for _, text in reader_rows(terminal.screen)]
        require(contains(terminal, 96) and reader_contains(terminal.screen, "Hi Alex,"),
                "small reader does not expose actual body text below its status/labels")
        require(not any("J/K Mail" in text for text in rows), "small focused reader wastes a repeated toolbar row")
        require("↑2 earlier" in terminal.text(), "anchored thread hides earlier cards without a cue")
        # The visible read status and labels add envelope rows. A short reader
        # must expose body immediately and let ordinary scrolling reach its
        # first substantive paragraph without changing the focused message.
        for _ in range(4):
            if reader_contains(terminal.screen, "The onboarding instructions are ready for this preview build."):
                break
            terminal.send(b"j")
            terminal.gap(.03)
        require(reader_contains(terminal.screen, "The onboarding instructions are ready for this preview build."),
                "small reader cannot reach its complete body paragraph by scrolling")
        rows = [text for _, text in reader_rows(terminal.screen)]
        require("3/3 mails" in terminal.text(), "compact body scrolling changed its focused thread message")
        # A word may move whole to another row; neither fragment should appear.
        require(not any("onboard" in text and "onboarding" not in text for text in rows), "plain reader splits onboarding inside the word")
        finish(terminal)
        print("PASS reader polish: focused Q/S anchor, compact reader body and word boundaries")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=("navigation", "search", "compact", "all"), default="all")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-reader-polish-") as temporary:
        root = Path(temporary)
        if args.case in ("navigation", "all"): navigation(args.binary.resolve(), root / "navigation")
        if args.case in ("search", "all"): search_return(args.binary.resolve(), root / "search")
        if args.case in ("compact", "all"): compact(args.binary.resolve(), root / "compact")


if __name__ == "__main__":
    main()
