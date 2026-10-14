#!/usr/bin/env python3
"""Deterministic focus handshakes using the real VT screen and wait helper.

No application, PTY process, desktop, fixture account or wall-clock sleep runs.
The controlled producer delays Tab handling and splits synchronized frames just
as separate PTY reads can, while unrelated complete redraws continue arriving.
"""
from __future__ import annotations

import heapq
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from terminal_pty import Terminal
from terminal_ux_batch_support import (BACKTAB, ENTER, TAB, FocusScreen,
                                      activate_button, focused, focus_button, wait_ux_filter)


class DelayedFocusTerminal(Terminal):
    def __init__(self, *, mono=False, empty=False, initial=0, stalled=False):
        self.screen = FocusScreen(40, 6)
        self.process = SimpleNamespace(poll=lambda: None)
        self.now = 0.0
        self.events = []
        self.sequence = 0
        self.next_key_at = 0.0
        self.current = initial
        self.mono, self.empty, self.stalled = mono, empty, stalled
        self.sent = []
        self.activated = []
        self.screen.feed(self.frame(initial) + self.frame_end())

    def frame(self, selected):
        highlight = b"\x1b[7m" if self.mono else b"\x1b[48;2;57;43;48m"
        controls = ((0, 1, 1, "Filter:"), (1, 2, 1, "Fixture focus"),
                    (2, 4, 1, "[Open]"), (3, 4, 10, "[Back]"))
        parts = [b"\x1b[?2026h\x1b[0m\x1b[2J"]
        for index, row, column, label in controls:
            if self.empty and index == 1:
                continue
            parts.append(f"\x1b[{row};{column}H".encode())
            if index == selected and not (self.empty and index == 2):
                parts.append(highlight)
            parts.extend((label.encode(), b"\x1b[0m"))
        parts.append(f"\x1b[5;1HClock {self.now:.3f}".encode())
        return b"".join(parts)

    @staticmethod
    def frame_end():
        return b"\x1b[6;1HTab Controls\x1b[?2026l"

    def schedule(self, when, callback):
        self.sequence += 1
        heapq.heappush(self.events, (when, self.sequence, callback))

    def display(self, selected):
        self.current = selected
        self.screen.feed(self.frame(selected))
        self.schedule(self.now + .05, lambda: self.screen.feed(self.frame_end()))

    def send(self, data):
        self.sent.append((data, self.now, self.screen.frame_open))
        if data == ENTER:
            self.activated.append(("Filter", "List", "Open", "Back")[self.current])
            return
        if data not in (TAB, BACKTAB):
            raise AssertionError(f"unexpected input: {data!r}")
        if len(self.sent) == 1:
            # A complete redraw with different text is not a Tab response.
            self.schedule(self.now + .02,
                          lambda: self.screen.feed(self.frame(self.current) + self.frame_end()))
        if not self.stalled:
            self.next_key_at = max(self.next_key_at, self.now) + .06
            direction = 1 if data == TAB else -1
            self.schedule(self.next_key_at,
                          lambda: self.display((self.current + direction) % 4))

    def pump(self, seconds=.05):
        end = self.now + seconds
        while self.events and self.events[0][0] <= end + 1e-9:
            self.now, _, callback = heapq.heappop(self.events)
            callback()
        self.now = end

    def gap(self, seconds=.25):
        self.pump(seconds)


class FocusCheck(unittest.TestCase):
    def test_contact_selection_ignores_same_address_in_highlighted_background(self):
        terminal = DelayedFocusTerminal()
        address = "second@example.test"
        chosen = f"› River <{address}>"
        terminal.screen.feed(("\x1b[2J\x1b[1;1H\x1b[7m" + address
                              + "\x1b[0m\x1b[3;1H› First <first@example.test>"
                              + f"\x1b[4;1H  River <{address}>").encode())
        self.assertTrue(focused(terminal, address))  # Old ambiguous precondition.
        self.assertFalse(focused(terminal, chosen))
        terminal.schedule(.06, lambda: terminal.screen.feed(
            ("\x1b[?2026h\x1b[3;1H  First <first@example.test>"
             + "\x1b[4;1H\x1b[7m" + chosen + "\x1b[0m").encode()))
        terminal.schedule(.11, lambda: terminal.screen.feed(terminal.frame_end()))
        with patch("terminal_pty.time.monotonic", lambda: terminal.now):
            terminal.until(lambda: focused(terminal, chosen))
        self.assertGreaterEqual(terminal.now, .11)
        self.assertEqual(terminal.events, [])
        self.assertEqual(terminal.sent, [])

    def test_existing_saved_row_does_not_acknowledge_pending_filter(self):
        terminal = DelayedFocusTerminal()
        detail = "Cache · subject:personal"
        row = "› Fixture focus"
        def filtered(query, close=True):
            frame = ("\x1b[?2026h\x1b[2J\x1b[1;1HFilter: " + query + "▏"
                     + "\x1b[2;1H" + row + "\x1b[3;1H" + detail).encode()
            terminal.screen.feed(frame + (terminal.frame_end() if close else b""))
        filtered("")  # The requested row/detail already exists before typing.
        terminal.schedule(.02, lambda: filtered("Fixture"))
        terminal.schedule(.06, lambda: filtered("Fixture focus", close=False))
        terminal.schedule(.11, lambda: terminal.screen.feed(terminal.frame_end()))
        with patch("terminal_pty.time.monotonic", lambda: terminal.now):
            wait_ux_filter(terminal, "Fixture focus", row, detail)
        self.assertGreaterEqual(terminal.now, .11)
        self.assertFalse(terminal.screen.frame_open)
        self.assertEqual(terminal.events, [])
        self.assertEqual(terminal.sent, [])

    def test_delayed_and_split_frames_never_queue_an_extra_tab(self):
        for mono in (False, True):
            with self.subTest(mono=mono):
                terminal = DelayedFocusTerminal(mono=mono)
                with patch("terminal_pty.time.monotonic", lambda: terminal.now):
                    activate_button(terminal, "[Open]")
                # The old 40ms loop queued three Tabs and activated Back after
                # its 260ms guard drained the still-pending third transition.
                self.assertEqual(terminal.activated, ["Open"])
                self.assertEqual([data for data, _, _ in terminal.sent], [TAB, TAB, ENTER])
                self.assertGreaterEqual(terminal.sent[1][1], .11)
                self.assertTrue(all(not partial for _, _, partial in terminal.sent))
                self.assertEqual(terminal.events, [])

    def test_empty_chooser_back_has_one_visible_reverse_transition(self):
        for mono in (False, True):
            with self.subTest(mono=mono):
                terminal = DelayedFocusTerminal(mono=mono, empty=True)
                with patch("terminal_pty.time.monotonic", lambda: terminal.now):
                    activate_button(terminal, "[Back]", backwards=True)
                self.assertEqual(terminal.activated, ["Back"])
                self.assertEqual([data for data, _, _ in terminal.sent], [BACKTAB, ENTER])

    def test_changed_focus_during_activation_guard_refuses_enter(self):
        terminal = DelayedFocusTerminal(initial=2)
        terminal.schedule(.06, lambda: terminal.display(3))
        with patch("terminal_pty.time.monotonic", lambda: terminal.now):
            with self.assertRaisesRegex(AssertionError, "action focus changed before Enter"):
                activate_button(terminal, "[Open]")
        self.assertEqual(terminal.sent, [])
        self.assertEqual(terminal.activated, [])

    def test_unchanged_focus_redraw_keeps_deadline_and_sends_no_second_tab(self):
        terminal = DelayedFocusTerminal(stalled=True)
        with patch("terminal_pty.time.monotonic", lambda: terminal.now):
            with self.assertRaisesRegex(AssertionError, "isolated PTY condition timed out"):
                focus_button(terminal, "[Open]")
        self.assertEqual([data for data, _, _ in terminal.sent], [TAB])
        self.assertGreaterEqual(terminal.now, 10)
        self.assertEqual(terminal.activated, [])

    def test_unreachable_control_keeps_32_step_bound(self):
        terminal = DelayedFocusTerminal()
        with patch("terminal_pty.time.monotonic", lambda: terminal.now):
            with self.assertRaisesRegex(AssertionError, "action is not reachable"):
                focus_button(terminal, "[Missing]")
        self.assertEqual([data for data, _, _ in terminal.sent], [TAB] * 32)
        self.assertEqual(terminal.activated, [])


if __name__ == "__main__":
    unittest.main()
