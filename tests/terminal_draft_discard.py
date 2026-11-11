#!/usr/bin/env python3
"""Untouched composers and explicit draft discard in owned fixture PTYs.

A new message, reply or forward left without a change keeps no draft;
typed, reopened and agent-filled drafts stay; Ctrl+X reviews discarding
from INSERT and the composer's Tab-reachable [Ctrl+X Discard] button. The
review is confirmed only by a gesture typing never produces (Ctrl+X again,
Enter on its focused [Ctrl+X Discard] or a click on it), and Ctrl+Z restores
a discarded draft exactly. Keys after any of it reach the user's next view
unchanged. No mail is sent, no mailbox mail changes, nothing is written to
Gmail.
"""
from __future__ import annotations

import argparse
import fcntl
from pathlib import Path
import signal
import struct
import tempfile
import termios
import time

from terminal_composer_workflow import composer, open_retained, setup
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_ux_batch_support import ENTER, ESC, TAB, diagnose, focus_button, focused, start

CTRL_X = b"\x18"
CTRL_Z = b"\x1a"
DOWN = b"\x1b[B"
UP = b"\x1b[A"
NOTHING_KEPT = "Nothing written · no draft kept"
DISCARDED = "Draft discarded · Ctrl+Z Undo"
HINT = "Ctrl+X again discards"
# A second Ctrl+X confirms only once the previous one has settled (1 s).
SETTLE = 1.2


def drafts(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        rows = client.request("draft.list")["drafts"]
        require(client.request("cache.stats")["fixtureSends"] == 0, "a draft workflow sent mail")
        return rows


def mailbox_untouched(binary, directory, extra, what):
    """No send, no provider write, no mailbox mutation (archive, star, read
    state, labels): the fixture provider records none of them."""
    with Client(binary, directory, extra=extra) as client:
        stats = client.request("cache.stats")
        require(stats["fixtureSends"] == 0, f"{what}: mail was sent")
        require(stats["fixtureProviderEntries"] == 0, f"{what}: mailbox mail changed ({stats['fixtureProviderEntries']} provider writes)")
        require(client.request("operation.list")["operations"] == [], f"{what}: a provider write was dispatched")


def in_mailbox(terminal, status=None):
    # A saved Back may hand the status row to the reader's own load at once;
    # the store, not the status, proves what was kept.
    terminal.until(lambda: "Subject:" not in terminal.text() and "[f Alias]" not in terminal.text()
                   and (status is None or status in terminal.text()))


def review(terminal, *content):
    terminal.until(lambda: all(value in terminal.text() for value in
                               ("Discard local draft", "Discard this draft?", "X Discard]", "[Esc Cancel]", *content)))


def run(binary, directory, body, columns=160, rows=40, send_grace=None):
    extra, message = setup(binary, directory)
    terminal = start(binary, directory, extra, message["bodyText"].splitlines()[0], columns=columns, rows=rows,
                     send_grace=send_grace)
    try:
        body(terminal, extra)
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


def confirm(terminal):
    """One deliberate Ctrl+X after the opening one has settled."""
    terminal.gap(SETTLE)
    terminal.send(CTRL_X)


def keys(terminal, sequence):
    for data, pause in sequence:
        terminal.gap(pause)
        terminal.send(data)


def chars(text, pace):
    return [(bytes([c]), pace) for c in text.encode()]


def untouched_twenty(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        for _ in range(20):
            composer(terminal)
            terminal.send(b"q")
            in_mailbox(terminal, NOTHING_KEPT)
        require(len(drafts(binary, directory, extra)) == before, "untouched composers left drafts behind")
        mailbox_untouched(binary, directory, extra, "untouched composers")
    run(binary, directory, body)


def typed_kept(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + TAB * 3 + b"Kept fixture subject")
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
        terminal.send(b"irecipient@example.test" + TAB * 3 + b"Discard from insert")
        terminal.until(lambda: "Discard from insert" in terminal.text()
                       and "Ctrl+X Discard" in terminal.screen.lines()[-2])
        terminal.send(CTRL_X)
        review(terminal, "Discard from insert · 1 recipient", "nothing is sent or changed in Gmail", "restores it until you quit")
        footer = terminal.screen.lines()[-2]
        require("Ctrl+X Discard" in footer and "Esc Keep draft" in footer and "Ctrl+S" not in footer,
                "the footer did not show the review's keys")
        # Esc keeps the draft and returns to INSERT with every typed letter.
        terminal.send(ESC)
        terminal.until(lambda: "Discard local draft" not in terminal.text() and "INSERT" in terminal.screen.lines()[-2])
        terminal.send(b" kept")
        terminal.until(lambda: "Discard from insert kept" in terminal.text())
        terminal.send(CTRL_X)
        review(terminal, "Discard from insert kept · 1 recipient")
        # y only explains; one deliberate Ctrl+X discards.
        terminal.gap(1.0)
        terminal.send(b"y")
        terminal.until(lambda: HINT in terminal.text())
        require("Discard local draft" in terminal.text(), "y closed or confirmed the review")
        confirm(terminal)
        in_mailbox(terminal, DISCARDED)
        require(len(drafts(binary, directory, extra)) == before, "Ctrl+X Discard kept the draft in Drafts")
        mailbox_untouched(binary, directory, extra, "Ctrl+X discard")
    run(binary, directory, body)


def type_through(binary, directory):
    """A stray Ctrl+X (or a vim habit) and then ordinary typing with human
    pauses: no stream discards the typed draft or reaches the mailbox."""
    streams = {
        # A thinking pause, then the next word starts with y.
        "slow-yes": [(b"y", 1.0)] + chars("es, I agree", .15),
        "thanks-pause-your": chars("Thanks for", .15) + [(b" ", .15), (b"y", 1.0)] + chars("our help", .15),
        # The rest of a sentence after a pause, as if the draft were gone.
        "pause-then-sentence": [(b"y", 1.0)] + chars("es", .12) + [(b" ", 1.0)] + chars("send the next one", .12),
        # nano habit: ^X, y (save?), Enter (file name).
        "nano": [(b"y", .7), (ENTER, .4)],
        # Tab to the next field, type, think, Enter for a new line.
        "tab-type-pause-enter": [(TAB, .3)] + chars("Hi Bob,", .12) + [(ENTER, 1.0)] + chars("next line", .12),
        "fast": chars("you yes yay", .1),
        "yyyy": chars("yyyy", .02),
        "arrows-enter": [(DOWN, .2), (ENTER, .2), (ENTER, .2)],
        "ctrl-n-enter": [(b"\x0e", .2), (ENTER, .2), (ENTER, .2)],
        # A held Ctrl+X: the first repeat after its delay, then repeats.
        "held-ctrl-x": [(CTRL_X, .66)] + [(CTRL_X, .03)] * 30,
    }

    def body(terminal, extra):
        typed_composer(terminal, "Typed through subject")
        terminal.gap(2.0)
        require(len(drafts(binary, directory, extra)) == 1, "the typed draft was not saved")
        for name, sequence in streams.items():
            require("Subject:" in terminal.text(), f"{name}: the composer closed")
            if "INSERT" not in terminal.screen.lines()[-2]:
                terminal.send(b"i")
                terminal.gap(.1)
            terminal.send(CTRL_X)
            keys(terminal, sequence)
            terminal.gap(1.2)
            rows = drafts(binary, directory, extra)
            require(len(rows) == 1 and rows[0]["subject"] == "Typed through subject",
                    f"{name}: typing on after a stray Ctrl+X discarded the typed draft")
            mailbox_untouched(binary, directory, extra, name)
            # Leave the review (if still open) and continue as the user would.
            if "Discard local draft" in terminal.text():
                terminal.send(ESC)
                terminal.until(lambda: "Discard local draft" not in terminal.text())
        require("Subject:" in terminal.text() and "Typed through subject" in terminal.text(), "the composer closed")
    run(binary, directory, body)


def vim_habits(binary, directory):
    """Normal mode: dd opens the review with its first d; a later yy after a
    pause must not confirm it."""
    def body(terminal, extra):
        typed_composer(terminal, "Vim subject", b"Line one of my text")
        terminal.send(ESC)
        terminal.gap(2.0)
        keys(terminal, [(b"d", 0), (b"d", .12), (b"y", 1.0), (b"y", .12)])
        terminal.gap(1.0)
        rows = drafts(binary, directory, extra)
        require(len(rows) == 1 and rows[0]["subject"] == "Vim subject", "vim dd … yy discarded the typed draft")
        mailbox_untouched(binary, directory, extra, "vim dd yy")
        terminal.send(ESC)
    run(binary, directory, body)


def discard_button(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + TAB * 3 + b"Discard by button" + ESC)
        terminal.gap(.06)
        terminal.until(lambda: "Discard by button" in terminal.text() and "[Ctrl+X Discard]" in terminal.text())
        # The composer button is reachable with Shift+Tab and activated by Enter.
        focus_button(terminal, "[Ctrl+X Discard]", backwards=True)
        terminal.send(ENTER)
        review(terminal, "Discard by button · no recipients")
        # Enter again lands on Cancel: an Enter typed ahead keeps the draft.
        terminal.send(ENTER)
        terminal.until(lambda: "Discard local draft" not in terminal.text())
        require(len(drafts(binary, directory, extra)) == before + 1, "Enter on Cancel discarded the draft")
        terminal.send(ENTER)
        review(terminal)
        # Tab reaches [Ctrl+X Discard]; Enter on it discards at once.
        terminal.send(TAB)
        terminal.until(lambda: focused(terminal, "[Ctrl+X Discard]") and "Discard local draft" in terminal.text())
        terminal.send(ENTER)
        in_mailbox(terminal, DISCARDED)
        require(len(drafts(binary, directory, extra)) == before, "the Discard button kept the draft")
    run(binary, directory, body)


def double_click(binary, directory):
    """A double click on [Ctrl+X Discard] opens the review; its second click
    may land on the review's own button and must not discard."""
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
            target = point(terminal, label)
            # Both presses of a real double click, back to back.
            click(terminal, *target)
            click(terminal, *target)
            review(terminal)
            terminal.gap(.6)
            require("Discard local draft" in terminal.text() and len(drafts(binary, case, extra)) == 1,
                    f"{size}: the second click of a double click discarded")
            terminal.send(ESC)
            terminal.resize(160, 40)
        return body
    for columns, rows in ((160, 40), (50, 16), (38, 18)):
        case = directory / f"{columns}x{rows}"
        run(binary, case, sized(case, columns, rows))


def raw_resize(terminal, columns, rows):
    """Below the harness's own bounds: draw() then shows only a resize request."""
    terminal.columns, terminal.rows = columns, rows
    terminal.screen = type(terminal.screen)(columns, rows)
    fcntl.ioctl(terminal.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows * 20, columns * 10))


def tiny_terminal(binary, directory):
    """A review no longer on screen (terminal shrunk below what draw()
    renders) never confirms, whatever is pressed."""
    def body(terminal, extra):
        typed_composer(terminal, "Tiny subject")
        terminal.send(ESC)
        terminal.gap(2.0)
        terminal.send(CTRL_X)
        review(terminal)
        for columns, rows in ((60, 8), (100, 9), (40, 10)):
            raw_resize(terminal, columns, rows)
            terminal.gap(.8)
            keys(terminal, [(CTRL_X, SETTLE), (TAB, .2), (ENTER, .2), (b"y", .2)])
            terminal.gap(.6)
            rows_now = drafts(binary, directory, extra)
            require(len(rows_now) == 1 and rows_now[0]["subject"] == "Tiny subject",
                    f"{columns}x{rows}: discarded while the review was not on screen")
        raw_resize(terminal, 160, 40)
        terminal.gap(.6)
        terminal.send(ESC)
        terminal.gap(.3)
        mailbox_untouched(binary, directory, extra, "tiny terminal")
    run(binary, directory, body)


def search_after_back(binary, directory):
    """q from an unchanged composer, then / and (after a pause) a query:
    every key reaches the search field, nothing runs on mail."""
    def body(terminal, extra):
        composer(terminal)
        terminal.gap(1.5)
        terminal.send(b"q")
        terminal.gap(.3)
        terminal.send(b"/")
        terminal.gap(.8)
        for byte in b"xmas":
            terminal.send(bytes([byte]))
            terminal.gap(.15)
        terminal.until(lambda: "xmas▏" in terminal.text())
        mailbox_untouched(binary, directory, extra, "q then /xmas")
        terminal.send(ESC)
        terminal.gap(.3)
    run(binary, directory, body)


def reopened_kept(binary, directory):
    def body(terminal, extra):
        before = len(drafts(binary, directory, extra))
        composer(terminal)
        terminal.send(b"i" + TAB * 3 + b"Reopened fixture subject")
        terminal.until(lambda: "Reopened fixture subject" in terminal.text())
        terminal.send(ESC)
        terminal.gap(.06)
        terminal.send(b"q")
        in_mailbox(terminal)
        require(len(drafts(binary, directory, extra)) == before + 1, "typed draft was not saved")
        # Reopen it from Drafts and leave without a change: it must stay.
        open_retained(terminal, "Reopened fixture subject")
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
    opens the usual conflict choice (the store refuses the guarded removal),
    and exit leaves it untouched too."""
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
            require(len(drafts(binary, directory, extra)) == before,
                    "an unchanged reply or forward left a draft (its quote is generated)")
    run(binary, directory, body)


def import_file(binary, directory, extra, name, data):
    path = directory / name
    path.write_bytes(data)
    with Client(binary, directory, extra=extra) as client:
        return client.request("attachment.import", path=str(path))


def drafts_view(binary, directory):
    """In Drafts: the review counts the real row (recipients, files); the
    notices survive the list reload; Ctrl+Z brings a discard back."""
    def body(terminal, extra):
        imported = import_file(binary, directory, extra, "fixture-notes.txt", b"Synthetic attachment\n")
        with Client(binary, directory, extra=extra) as client:
            client.request("draft.create", draft={"to": ["ana@example.test", "bo@example.test"], "cc": ["cy@example.test"],
                                                  "subject": "Counted draft", "bodyText": "Note", "attachments": [imported]})
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Counted draft" in terminal.text())
        terminal.gap(.3)
        terminal.send(b":discard-draft\r")
        review(terminal, "Counted draft · 3 recipients · 1 file")
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
        # Explicit discard of the reopened draft: the notice stays too.
        terminal.send(b"\r")
        terminal.until(lambda: "Subject: Counted draft" in terminal.text() and "[Ctrl+X Discard]" in terminal.text())
        terminal.gap(.2)
        terminal.send(CTRL_X)
        review(terminal, "Counted draft · 3 recipients")
        confirm(terminal)
        terminal.until(lambda: "Subject:" not in terminal.text() and "Counted draft" not in terminal.text())
        terminal.gap(1.5)
        require(DISCARDED in terminal.screen.lines()[-1], "the discard notice vanished in Drafts")
        require(drafts(binary, directory, extra) == [], "the reviewed draft stayed in Drafts")
        # Ctrl+Z restores it and reopens it in the composer.
        terminal.send(CTRL_Z)
        terminal.until(lambda: "Subject: Counted draft" in terminal.text())
        require([row["subject"] for row in drafts(binary, directory, extra)] == ["Counted draft"], "Ctrl+Z did not restore the draft")
        terminal.send(ESC)
        terminal.gap(.1)
        terminal.send(b"q")
        in_mailbox(terminal)
        mailbox_untouched(binary, directory, extra, "Drafts view")
    run(binary, directory, body)


def undo_exact(binary, directory):
    """A reply draft with recipients, threading, a sender and a file:
    discard, Ctrl+Z, and draft.read is the same before and after. A second
    discard replaces the kept one, which is then gone for good."""
    def body(terminal, extra):
        imported = import_file(binary, directory, extra, "undo-notes.txt", b"Synthetic undo attachment\n")
        with Client(binary, directory, extra=extra) as client:
            first = client.request("draft.create", draft={"from": {"address": "personal@example.com", "name": "Fixture account"},
                                                          "to": [{"address": "peer@example.test", "name": "Peer Fixture"}], "cc": ["cc@example.test"],
                                                          "subject": "Re: Undo plan", "bodyText": "Typed reply worth keeping",
                                                          "threadId": "thread-undo", "inReplyTo": "<source@example.test>",
                                                          "references": "<root@example.test> <source@example.test>", "attachments": [imported]})
            before = client.request("draft.read", draftId=first["id"])
        open_retained(terminal, "Re: Undo plan")
        terminal.send(CTRL_X)
        review(terminal, "Re: Undo plan · 2 recipients · 1 file")
        confirm(terminal)
        in_mailbox(terminal, DISCARDED)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("draft.read", ok=False, draftId=first["id"])["code"] == "DraftNotFound", "a kept draft is still readable")
        terminal.send(CTRL_Z)
        terminal.until(lambda: "Subject: Re: Undo plan" in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            after = client.request("draft.read", draftId=first["id"])
        require(after == before, "Ctrl+Z did not restore the draft exactly")
        # Discard it again, then another draft: only the second is kept.
        terminal.send(ESC)
        terminal.gap(.1)
        terminal.send(CTRL_X)
        review(terminal)
        confirm(terminal)
        in_mailbox(terminal, DISCARDED)
        with Client(binary, directory, extra=extra) as client:
            client.request("draft.create", draft={"to": ["second@example.test"], "subject": "Second kept draft", "bodyText": "Second"})
        # Leave Drafts so opening it again lists the new draft.
        click(terminal, *point(terminal, "Inbox"))
        terminal.until(lambda: "Inbox ·" in terminal.screen.lines()[0])
        open_retained(terminal, "Second kept draft")
        terminal.send(CTRL_X)
        review(terminal)
        confirm(terminal)
        in_mailbox(terminal, DISCARDED)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("draft.restore", ok=False, draftId=first["id"])["code"] == "DiscardedDraftUnavailable",
                    "a replaced discard could still be restored")
        terminal.send(CTRL_Z)
        terminal.until(lambda: "Subject: Second kept draft" in terminal.text())
        require([row["subject"] for row in drafts(binary, directory, extra)] == ["Second kept draft"], "the wrong draft came back")
        terminal.send(ESC)
        terminal.gap(.1)
        terminal.send(b"q")
        in_mailbox(terminal)
        mailbox_untouched(binary, directory, extra, "undo")
    run(binary, directory, body)


def undo_after_restart(binary, directory):
    """What a window keeps for Ctrl+Z goes for good when it quits, and a
    window that ended without a clean exit leaves nothing for the next."""
    extra, message = setup(binary, directory)
    first = message["bodyText"].splitlines()[0]
    for ending in ("quit", "killed"):
        terminal = start(binary, directory, extra, first)
        try:
            typed_composer(terminal, f"Restart {ending}")
            terminal.send(ESC)
            terminal.gap(2.0)
            terminal.send(CTRL_X)
            review(terminal)
            confirm(terminal)
            in_mailbox(terminal, DISCARDED)
            if ending == "quit":
                terminal.finish()
            else:
                terminal.process.send_signal(signal.SIGKILL)
                terminal.process.wait(timeout=5)
        except Exception:
            diagnose(terminal)
            raise
        finally:
            terminal.close()
        if ending == "killed":
            # The next window drops the leftover when it starts.
            terminal = start(binary, directory, extra, first)
            try:
                terminal.send(CTRL_Z)
                terminal.gap(.6)
                require("Subject:" not in terminal.text(), "a new window restored an earlier window's discard")
                terminal.finish()
            finally:
                terminal.close()
        with Client(binary, directory, extra=extra) as client:
            require(client.request("draft.restore", ok=False)["code"] == "DiscardedDraftUnavailable",
                    f"{ending}: a discarded draft outlived its window")
            require(client.request("draft.list")["drafts"] == [], f"{ending}: the discarded draft came back")
    mailbox_untouched(binary, directory, extra, "restart")


def sender_less(binary, directory):
    """A draft written without a sender (an agent or the CLI) opens without
    a false "changed elsewhere": the composer's default sender is its own."""
    def body(terminal, extra):
        with Client(binary, directory, extra=extra) as client:
            client.request("draft.create", draft={"to": ["peer@example.test"], "subject": "CLI created draft", "bodyText": "Agent body"})
        open_retained(terminal, "CLI created draft")
        terminal.gap(2.5)
        require("changed elsewhere" not in terminal.text(), "a sender-less draft looked changed elsewhere")
        terminal.send(b"q")
        in_mailbox(terminal)
        require("changed elsewhere" not in terminal.text(), "leaving a sender-less draft reported a conflict")
        require([row["subject"] for row in drafts(binary, directory, extra)] == ["CLI created draft"], "the draft was not kept")
    run(binary, directory, body)


def removed_elsewhere(binary, directory):
    """A typed draft removed by another program: Back keeps the text as a
    new draft instead of failing to save it."""
    def body(terminal, extra):
        typed_composer(terminal, "Removed elsewhere subject")
        terminal.send(ESC)
        terminal.gap(2.0)
        with Client(binary, directory, extra=extra) as client:
            target = client.request("draft.list")["drafts"][0]["id"]
            client.request("draft.discard", draftId=target)
        terminal.send(b"q")
        # The reader's own load may take the status row at once; the store
        # proves what was kept.
        in_mailbox(terminal)
        terminal.gap(.5)
        rows = drafts(binary, directory, extra)
        require(len(rows) == 1 and rows[0]["subject"] == "Removed elsewhere subject" and rows[0]["id"] != target,
                "the text of a draft removed elsewhere was not kept")
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
                terminal.gap(SETTLE)
                terminal.send(CTRL_X)
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
         ("insert-ctrl-x", insert_ctrl_x), ("type-through", type_through), ("vim-habits", vim_habits),
         ("discard-button", discard_button), ("double-click", double_click), ("tiny-terminal", tiny_terminal),
         ("search-after-back", search_after_back), ("reopened-kept", reopened_kept), ("agent-filled", agent_filled),
         ("reply-forward-untouched", reply_forward_untouched), ("drafts-view", drafts_view),
         ("undo-exact", undo_exact), ("undo-after-restart", undo_after_restart),
         ("sender-less", sender_less), ("removed-elsewhere", removed_elsewhere),
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
