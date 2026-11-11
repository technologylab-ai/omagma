#!/usr/bin/env python3
"""Untouched composers and explicit draft discard in owned fixture PTYs.

A new message, reply or forward left without a change keeps no draft;
typed and reopened drafts stay; Ctrl+X reviews discarding from INSERT and
the composer's Tab-reachable [Ctrl+X Discard] button. No mail is sent.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import tempfile

from terminal_composer_workflow import composer, open_retained, setup
from terminal_integration import Client, require
from terminal_ux_batch_support import ENTER, ESC, activate_button, diagnose, focus_button, start

CTRL_X = b"\x18"
NOTHING_KEPT = "Nothing written · no draft kept"


def drafts(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        rows = client.request("draft.list")["drafts"]
        require(client.request("cache.stats")["fixtureSends"] == 0, "a draft workflow sent mail")
        return rows


def in_mailbox(terminal, status=None):
    # A saved Back may hand the status row to the reader's own load at once;
    # the store, not the status, proves what was kept.
    terminal.until(lambda: "Subject:" not in terminal.text() and "[f Alias]" not in terminal.text()
                   and (status is None or status in terminal.text()))


def review(terminal, *content):
    terminal.until(lambda: all(value in terminal.text() for value in
                               ("Discard local draft", "Discard this draft? It can't be restored.",
                                "[y Discard]", "[Esc Cancel]", *content)))


def run(binary, directory, body):
    extra, message = setup(binary, directory)
    terminal = start(binary, directory, extra, message["bodyText"].splitlines()[0])
    try:
        body(terminal, extra)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def untouched_twenty(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        for _ in range(20):
            composer(terminal)
            terminal.send(b"q")
            in_mailbox(terminal, NOTHING_KEPT)
        require(len(drafts(binary, directory, extra)) == before, "untouched composers left drafts behind")
    run(binary, directory, body)


def typed_kept(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + b"\t" * 3 + b"Kept fixture subject")
        terminal.until(lambda: "Kept fixture subject" in terminal.text())
        terminal.send(ESC)
        terminal.gap(.06)
        terminal.send(b"q")
        in_mailbox(terminal)
        rows = drafts(binary, directory, extra)
        require(len(rows) == before + 1 and any(row["subject"] == "Kept fixture subject" for row in rows),
                "a draft with typed text was not kept")
    run(binary, directory, body)


def insert_ctrl_x(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"irecipient@example.test" + b"\t" * 3 + b"Discard from insert")
        terminal.until(lambda: "Discard from insert" in terminal.text()
                       and "Ctrl+X Discard" in terminal.screen.lines()[-2])
        terminal.send(CTRL_X)
        review(terminal, "Discard from insert · 1 recipient", "nothing is sent or changed in Gmail")
        # Esc keeps the draft and returns to INSERT with every typed letter.
        terminal.send(ESC)
        terminal.until(lambda: "Discard local draft" not in terminal.text() and "INSERT" in terminal.screen.lines()[-2])
        terminal.send(b" kept")
        terminal.until(lambda: "Discard from insert kept" in terminal.text())
        terminal.send(CTRL_X)
        review(terminal, "Discard from insert kept · 1 recipient")
        # A y while the review is new is refused; one deliberate press later works.
        terminal.send(b"y")
        terminal.until(lambda: "press y once more" in terminal.text() and "[y Discard]" in terminal.text())
        terminal.gap(2.2)
        terminal.send(b"y")
        in_mailbox(terminal, "Draft discarded")
        require(len(drafts(binary, directory, extra)) == before, "Ctrl+X Discard kept the draft")
    run(binary, directory, body)


def discard_button(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + b"\t" * 3 + b"Discard by button" + ESC)
        terminal.gap(.06)
        terminal.until(lambda: "Discard by button" in terminal.text() and "[Ctrl+X Discard]" in terminal.text())
        # The composer button is reachable with Shift+Tab and activated by Enter.
        focus_button(terminal, "[Ctrl+X Discard]", backwards=True)
        terminal.send(ENTER)
        review(terminal, "Discard by button · no recipients")
        activate_button(terminal, "[y Discard]", backwards=True)
        in_mailbox(terminal, "Draft discarded")
        require(len(drafts(binary, directory, extra)) == before, "the Discard button kept the draft")
    run(binary, directory, body)


def reopened_kept(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + b"\t" * 3 + b"Reopened fixture subject")
        terminal.until(lambda: "Reopened fixture subject" in terminal.text())
        terminal.send(ESC)
        terminal.gap(.06)
        terminal.send(b"q")
        in_mailbox(terminal)
        require(len(drafts(binary, directory, extra)) == before + 1, "typed draft was not saved")
        # Reopen it from Drafts and leave without a change: it must stay.
        open_retained(terminal, "Reopened fixture subject")
        # Receipts are checked first; only then is the draft editable and
        # offered for Discard (a protected draft has no Discard button).
        terminal.until(lambda: "Compose · Draft" in terminal.text() and "[Ctrl+X Discard]" in terminal.text())
        terminal.gap(.05)
        terminal.send(b"q")
        terminal.until(lambda: "Subject:" not in terminal.text() and NOTHING_KEPT not in terminal.text())
        terminal.gap(.3)
        rows = drafts(binary, directory, extra)
        require(len(rows) == before + 1 and any(row["subject"] == "Reopened fixture subject" for row in rows),
                "a reopened draft was removed by an unchanged Back")
    run(binary, directory, body)


def open_source_composer(terminal, key):
    terminal.send(key)
    terminal.until(lambda: "[Text quote t]" in terminal.text()
                   or ("Subject:" in terminal.text() and "[f Alias]" in terminal.text()))
    if "[Text quote t]" in terminal.text():
        terminal.send(b"t")
    terminal.until(lambda: "Subject:" in terminal.text() and "[f Alias]" in terminal.text()
                   and "Ctrl+S Review" in terminal.text())
    terminal.gap(.05)


def reply_forward_untouched(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        for key in (b"r", b"f"):
            open_source_composer(terminal, key)
            # Ctrl+C is Back too.
            terminal.send(b"q" if key == b"r" else b"\x03")
            in_mailbox(terminal, NOTHING_KEPT)
            require(len(drafts(binary, directory, extra)) == before,
                    "an unchanged reply or forward left a draft (its quote is generated)")
    run(binary, directory, body)


def signal_untouched(binary, directory):
    extra, message = setup(binary, directory)
    before = len(drafts(binary, directory, extra))
    terminal = start(binary, directory, extra, message["bodyText"].splitlines()[0])
    try:
        composer(terminal)
        terminal.finish(signal_mode=True)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()
    require(len(drafts(binary, directory, extra)) == before, "exit with an untouched composer kept a draft")


CASES = (("untouched-twenty", untouched_twenty), ("typed-kept", typed_kept),
         ("insert-ctrl-x", insert_ctrl_x), ("discard-button", discard_button),
         ("reopened-kept", reopened_kept), ("reply-forward-untouched", reply_forward_untouched),
         ("signal-untouched", signal_untouched))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=[name for name, _ in CASES], action="append")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-draft-discard-") as temporary:
        for name, case in CASES:
            if args.case and name not in args.case:
                continue
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            case(args.binary.resolve(), directory)
            print(f"PASS draft discard: {name}", flush=True)


if __name__ == "__main__":
    main()
