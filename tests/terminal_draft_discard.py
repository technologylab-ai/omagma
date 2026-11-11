#!/usr/bin/env python3
"""Untouched composers and explicit draft discard in owned fixture PTYs.

A new message, reply or forward left without a change keeps no draft;
typed, reopened and agent-filled drafts stay; Ctrl+X reviews discarding
from INSERT and the composer's Tab-reachable [Ctrl+X Discard] button. The
review confirms only on a still keyboard, and keys typed after a discard
never reach the mailbox. No mail is sent and nothing is written to Gmail.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import signal
import tempfile
import time

from terminal_composer_workflow import composer, open_retained, setup
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_ux_batch_support import ENTER, ESC, BACKTAB, TAB, diagnose, focus_button, focused, no_writes, start

CTRL_X = b"\x18"
DOWN = b"\x1b[B"
UP = b"\x1b[A"
NOTHING_KEPT = "Nothing written · no draft kept"
# After a discard or an untouched Back, keys are dropped until the keyboard
# has been quiet this long; tests pause before their next deliberate key.
QUIET = .75


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
                               ("Discard local draft", "Discard this draft?" if terminal.columns < 60
                                else "Discard this draft? It can't be restored.", "[y Discard]", "[Esc Cancel]", *content)))


def run(binary, directory, body, columns=160, rows=40, send_grace=None):
    extra, message = setup(binary, directory)
    terminal = start(binary, directory, extra, message["bodyText"].splitlines()[0], columns=columns, rows=rows,
                     send_grace=send_grace)
    try:
        body(terminal, extra)
        terminal.gap(QUIET)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def typed_composer(terminal, subject, body=b"Paragraph I spent time writing."):
    composer(terminal)
    terminal.send(b"irecipient@example.test" + TAB * 3 + subject.encode() + TAB + body)
    terminal.until(lambda: body.decode() in terminal.text() and subject in terminal.text())


def untouched_twenty(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        for _ in range(20):
            composer(terminal)
            terminal.send(b"q")
            in_mailbox(terminal, NOTHING_KEPT)
            terminal.gap(QUIET)
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
        require("y Discard" in terminal.screen.lines()[-2] and "Ctrl+S" not in terminal.screen.lines()[-2],
                "the footer did not show the review's keys")
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
        # Typed straight after the discard (the rest of a sentence): never
        # archive, mark unread or Trash mail.
        for key in b"Next one, xuD":
            terminal.gap(.12)
            terminal.send(bytes([key]))
        terminal.gap(.3)
        require("Undo" not in terminal.screen.lines()[-1] and "Move selected mail to Trash" not in terminal.text(),
                f"keys typed after a discard acted on mail: {terminal.screen.lines()[-1]!r}")
        no_writes(binary, directory, extra)
        require(len(drafts(binary, directory, extra)) == before, "Ctrl+X Discard kept the draft")
    run(binary, directory, body)


def type_through(binary, directory):
    """A stray Ctrl+X while typing, then ordinary keys at 20–200 ms: no
    stream discards the typed draft or acts on mail."""
    streams = {
        "hello-you": [(c, .15) for c in b"Hello, you"],
        "thank-you": [(c, .12) for c in b"Thank you"],
        "yyyy": [(c, .02) for c in b"yyyy"],
        "enter-spam": [(13, .05)] * 6,
        "arrows-enter": [(DOWN, .2), (ENTER, .2), (ENTER, .2)],
        "ctrl-n-enter": [(b"\x0e", .2), (ENTER, .2), (ENTER, .2)],
        "nano-ctrl-x-y": [(ord("y"), .1)],
        # A held y: first press, the repeat after its delay, then repeats.
        "held-y-250": [(ord("y"), .02), (ord("y"), .25)] + [(ord("y"), .03)] * 5,
        "held-y-500": [(ord("y"), .02), (ord("y"), .5)] + [(ord("y"), .03)] * 5,
        "held-y-600": [(ord("y"), .02), (ord("y"), .6)] + [(ord("y"), .03)] * 5,
        "held-y-1000": [(ord("y"), .02), (ord("y"), 1.0)] + [(ord("y"), .03)] * 5,
    }

    def body(terminal, extra):
        typed_composer(terminal, "Typed through subject")
        terminal.gap(2.0)
        before = drafts(binary, directory, extra)
        require(len(before) == 1, "the typed draft was not saved")
        for name, keys in streams.items():
            if "Subject:" not in terminal.text():
                require(False, f"{name}: the composer closed")
            if "INSERT" not in terminal.screen.lines()[-2]:
                terminal.send(b"i")
                terminal.gap(.1)
            terminal.send(CTRL_X)
            for key, pause in keys:
                terminal.gap(pause)
                terminal.send(key if isinstance(key, bytes) else bytes([key]))
            terminal.gap(.4)
            rows = drafts(binary, directory, extra)
            require(len(rows) == 1 and rows[0]["subject"] == "Typed through subject",
                    f"{name}: typing on after a stray Ctrl+X discarded the typed draft")
            no_writes(binary, directory, extra)
            # Leave the review (if still open) and continue as the user would.
            terminal.send(ESC)
            terminal.gap(.3)
        require("Subject:" in terminal.text() and "Typed through subject" in terminal.text(), "the composer closed")
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
        # Only the two buttons take focus; Enter on [y Discard] needs a pause.
        terminal.send(BACKTAB)
        terminal.until(lambda: focused(terminal, "[y Discard]"))
        terminal.send(ENTER)
        terminal.until(lambda: "press y once more" in terminal.text())
        require("Discard local draft" in terminal.text(), "a quick Enter after Tab discarded")
        terminal.gap(2.2)
        terminal.send(ENTER)
        in_mailbox(terminal, "Draft discarded")
        require(len(drafts(binary, directory, extra)) == before, "the Discard button kept the draft")
    run(binary, directory, body)


def double_click(binary, directory):
    """A double click on [Ctrl+X Discard] opens the review; its second click
    may land on [y Discard] and must not discard."""
    def sized(case, columns, rows):
        def body(terminal, extra):
            typed_composer(terminal, "Double click subject")
            terminal.send(ESC)
            terminal.gap(2.0)
            size = f"{columns}x{rows}"
            require(len(drafts(binary, case, extra)) == 1, f"{size}: the typed draft was not saved")
            # Typed at full size, then narrowed to where the labels shorten.
            terminal.resize(columns, rows)
            terminal.until(lambda: "X Discard]" in terminal.text() and "Subject:" in terminal.text())
            terminal.gap(.3)
            label = "[Ctrl+X Discard]" if terminal.screen.locate("[Ctrl+X Discard]") else "[^X Discard]"
            click(terminal, *point(terminal, label))
            review(terminal)
            click(terminal, *point(terminal, "[y Discard]"))
            terminal.gap(.6)
            require("Discard local draft" in terminal.text() and len(drafts(binary, case, extra)) == 1,
                    f"{size}: the second click of a double click discarded")
            terminal.send(ESC)
            terminal.resize(160, 40)
        return body
    for columns, rows in ((160, 40), (50, 16), (38, 18)):
        case = directory / f"{columns}x{rows}"
        run(binary, case, sized(case, columns, rows))


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


def agent_filled(binary, directory):
    """An agent fills the draft the composer just opened; Back keeps it and
    opens the usual conflict choice, and exit leaves it untouched too."""
    extra, message = setup(binary, directory)
    terminal = start(binary, directory, extra, message["bodyText"].splitlines()[0])
    try:
        composer(terminal)
        terminal.gap(2.0)
        with Client(binary, directory, extra=extra) as client:
            target = client.request("draft.list")["drafts"][0]["id"]
            client.request("draft.update", draftId=target, draft={"to": ["boss@example.test"], "subject": "Agent-written reply",
                                                                  "bodyText": "Long text an agent drafted.", "bodyFormat": "markdown"})
        terminal.send(b"q")
        terminal.until(lambda: "Keep local text or load the saved version" in terminal.text())
        rows = drafts(binary, directory, extra)
        require(len(rows) == 1 and rows[0]["subject"] == "Agent-written reply", "Back removed or replaced agent-written content")
        terminal.gap(QUIET)
        terminal.send(ESC)
        terminal.gap(.3)
        terminal.finish(signal_mode=True)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()
    with Client(binary, directory, extra=extra) as client:
        kept = client.request("draft.read", draftId=target)
        require(kept["subject"] == "Agent-written reply" and kept["bodyText"] == "Long text an agent drafted.",
                "exit overwrote or removed agent-written content")
        require(client.request("cache.stats")["fixtureSends"] == 0, "a draft workflow sent mail")


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
            terminal.gap(QUIET)
            require(len(drafts(binary, directory, extra)) == before,
                    "an unchanged reply or forward left a draft (its quote is generated)")
    run(binary, directory, body)


def drafts_view(binary, directory):
    """In Drafts: the review counts the real row (recipients, file copies);
    the notices survive the list reload; a queued draft is refused."""
    def body(terminal, extra):
        attachment = directory / "fixture-notes.txt"
        attachment.write_bytes(b"Synthetic attachment\n")
        with Client(binary, directory, extra=extra) as client:
            imported = client.request("attachment.import", path=str(attachment))
            client.request("draft.create", draft={"to": ["ana@example.test", "bo@example.test"], "cc": ["cy@example.test"],
                                                  "subject": "Counted draft", "bodyText": "Note", "attachments": [imported]})
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Counted draft" in terminal.text())
        terminal.gap(.3)
        terminal.send(b":discard-draft\r")
        review(terminal, "Counted draft · 3 recipients", "1 attached file copy")
        terminal.send(ESC)
        terminal.gap(.3)
        # An untouched composer from Drafts: the notice stays after the reload.
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Ctrl+S Review" in terminal.text())
        terminal.gap(.1)
        terminal.send(b"q")
        terminal.until(lambda: "Subject:" not in terminal.text() and "Counted draft" in terminal.text())
        terminal.gap(1.5)
        require(NOTHING_KEPT in terminal.screen.lines()[-1], "the untouched Back notice vanished in Drafts")
        terminal.gap(QUIET)
        # Explicit discard of the reopened draft: the notice stays too.
        terminal.send(b"\r")
        terminal.until(lambda: "Subject: Counted draft" in terminal.text() and "[Ctrl+X Discard]" in terminal.text())
        terminal.gap(.2)
        terminal.send(CTRL_X)
        review(terminal, "Counted draft · 3 recipients")
        terminal.gap(.8)
        terminal.send(b"y")
        terminal.until(lambda: "Subject:" not in terminal.text() and "Counted draft" not in terminal.text())
        terminal.gap(1.5)
        require("Draft discarded" in terminal.screen.lines()[-1], "the discard notice vanished in Drafts")
        require(drafts(binary, directory, extra) == [], "the reviewed draft was not discarded")
    run(binary, directory, body)


def paused_queue(binary, directory):
    """A send paused by an exit stays protected in the composer and the
    Drafts list alike: nothing is cancelled or discarded."""
    extra, message = setup(binary, directory)
    first = message["bodyText"].splitlines()[0]
    terminal = start(binary, directory, extra, first, send_grace=30)
    try:
        typed_composer(terminal, "Paused queue subject")
        terminal.send(ESC)
        terminal.gap(.3)
        terminal.send(b"\x13")
        terminal.until(lambda: "[y Send]" in terminal.text(), 8)
        terminal.gap(.8)
        terminal.send(b"y")
        terminal.until(lambda: "Undo" in terminal.text(), 5)
        terminal.process.send_signal(signal.SIGKILL)
        terminal.process.wait(timeout=5)
    finally:
        terminal.close()
    terminal = start(binary, directory, extra, first, send_grace=30)
    try:
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Paused queue subject" in terminal.text())
        terminal.gap(.3)
        # Refused before any review, as Ctrl+X in its composer is.
        terminal.send(b":discard-draft\r")
        terminal.until(lambda: "a send is queued for it" in terminal.text())
        require("Discard local draft" not in terminal.text(), "the Drafts list offered to discard a queued draft")
        terminal.gap(QUIET)
        terminal.send(b"\r")
        terminal.until(lambda: "Subject: Paused queue subject" in terminal.text())
        terminal.gap(1.5)
        terminal.send(CTRL_X)
        terminal.until(lambda: "a send is queued for it" in terminal.text())
        require("Discard local draft" not in terminal.text(), "the composer offered to discard a queued draft")
        with Client(binary, directory, extra=extra) as client:
            queue = client.request("queue.list")["queue"]
            require(queue and all(entry["state"] == "queued" for entry in queue), "a queued send was cancelled")
            require(len(client.request("draft.list")["drafts"]) == 1, "a draft with a queued send was discarded")
            require(client.request("cache.stats")["fixtureSends"] == 0, "the queued send was sent")
        terminal.process.send_signal(signal.SIGKILL)
        terminal.process.wait(timeout=5)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def width_sweep(binary, directory):
    """Discard is visible as a button and a footer key at every width."""
    def body(terminal, extra):
        composer(terminal)
        terminal.gap(1.0)
        for mode in ("normal", "insert"):
            if mode == "insert":
                terminal.send(b"i")
                terminal.gap(.2)
            for rows in (30, 16):
                for width in range(38, 161, 3):
                    terminal.resize(width, rows)
                    terminal.until(lambda: "Subject:" in terminal.text() and terminal.screen.lines()[-2].strip())
                    terminal.gap(.08)
                    text = terminal.text()
                    button = "[Ctrl+X Discard]" in text or "[^X Discard]" in text
                    # Narrow footers name it ^X Discard, like the button.
                    hint = "X Discard" in terminal.screen.lines()[-2]
                    require(button and hint, f"{mode} {width}x{rows}: Discard button={button} footer={hint}")
        terminal.resize(160, 40)
        terminal.send(ESC)
    run(binary, directory, body, columns=160, rows=30)


def exit_race(binary, directory):
    """q (untouched) or a confirmed discard, then SIGTERM within milliseconds:
    a clean exit and no draft left behind."""
    # The window is a few milliseconds wide; several delays make the race
    # likely to be hit, never a reason for a slower success.
    delays = (0, .0005, .001, .0015, .002, .0025, .003, .004, .006, .008)
    for index, (key, delay) in enumerate([(b"q", d) for d in delays] + [(CTRL_X, d) for d in (0, .001, .002, .005)]):
        case = directory / f"race-{index}"
        extra, message = setup(binary, case)
        terminal = start(binary, case, extra, message["bodyText"].splitlines()[0])
        try:
            if key == CTRL_X:
                typed_composer(terminal, "Raced discard")
                terminal.send(CTRL_X)
                review(terminal)
                terminal.gap(.8)
                terminal.send(b"y")
            else:
                composer(terminal)
                terminal.gap(1.8)
                terminal.send(b"q")
            if delay:
                time.sleep(delay)
            terminal.process.send_signal(signal.SIGTERM)
            deadline = time.monotonic() + 6
            while terminal.process.poll() is None and time.monotonic() < deadline:
                terminal.pump()
            code = terminal.process.poll()
            tail = bytes(terminal.output[-800:]).decode("utf-8", "replace")
            require(code == 0 and "DraftPersistenceFailed" not in tail, f"exit {code} after {key!r} + SIGTERM at {delay}s: {tail[-200:]!r}")
        finally:
            terminal.close()
        # An untouched Back keeps no draft whichever side of the signal it
        # landed on; a typed draft is either discarded or saved, never lost.
        if key == b"q":
            require(drafts(binary, case, extra) == [], f"a draft survived q + SIGTERM at {delay}s")


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
         ("insert-ctrl-x", insert_ctrl_x), ("type-through", type_through),
         ("discard-button", discard_button), ("double-click", double_click),
         ("reopened-kept", reopened_kept), ("agent-filled", agent_filled),
         ("reply-forward-untouched", reply_forward_untouched), ("drafts-view", drafts_view),
         ("paused-queue", paused_queue), ("width-sweep", width_sweep),
         ("exit-race", exit_race), ("signal-untouched", signal_untouched))


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
