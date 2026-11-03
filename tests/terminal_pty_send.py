#!/usr/bin/env python3
"""Offline native-PTY sender oracles; no terminal, account or desktop access."""
import selectors
import unittest
from unittest.mock import Mock, patch

import terminal_pty


class PtySend(unittest.TestCase):
    def terminal(self):
        terminal = terminal_pty.Terminal.__new__(terminal_pty.Terminal)
        terminal.master = 123
        terminal.pump = Mock()
        return terminal

    def test_short_and_interrupted_writes_retain_every_requested_byte(self):
        terminal = self.terminal()
        wire = bytearray()
        counts = iter((InterruptedError(), 2, 1, 3))

        def write(fd, data):
            self.assertEqual(fd, terminal.master)
            count = next(counts)
            if isinstance(count, Exception):
                raise count
            wire.extend(data[:count])
            return count

        with patch.object(terminal_pty.os, "write", side_effect=write):
            terminal.send(b"abcdef")
        self.assertEqual(wire, b"abcdef")
        self.assertFalse(terminal._send_pending)
        self.assertEqual(terminal._send_bytes, 0)

    def test_backpressure_defers_reentrant_query_reply_until_paste_finishes(self):
        terminal = self.terminal()
        wire = bytearray()
        counts = iter((2, BlockingIOError(), 2, 5))

        def write(fd, data):
            self.assertEqual(fd, terminal.master)
            count = next(counts)
            if isinstance(count, Exception):
                raise count
            wire.extend(data[:count])
            return count

        waiter = Mock()
        waiter.select.return_value = [(None, selectors.EVENT_READ)]
        terminal.pump.side_effect = lambda seconds: terminal.send(b"QUERY")
        with patch.object(terminal_pty.os, "write", side_effect=write), \
                patch.object(terminal_pty.selectors, "DefaultSelector", return_value=waiter), \
                patch.object(terminal_pty.time, "sleep", side_effect=AssertionError("no fixed sleeps")):
            terminal.send(b"BODY")
        self.assertEqual(wire, b"BODYQUERY")
        terminal.pump.assert_called_once_with(0)
        waiter.register.assert_called_once_with(terminal.master, selectors.EVENT_READ | selectors.EVENT_WRITE)
        waiter.close.assert_called_once_with()

    def test_backpressure_keeps_the_existing_ten_second_bound_and_drops_failed_input(self):
        terminal = self.terminal()
        waiter = Mock()
        waiter.select.return_value = []
        with patch.object(terminal_pty.os, "write", side_effect=BlockingIOError()), \
                patch.object(terminal_pty.selectors, "DefaultSelector", return_value=waiter), \
                patch.object(terminal_pty.time, "monotonic", side_effect=(0, 0, 0, 11)), \
                patch.object(terminal_pty.time, "sleep", side_effect=AssertionError("no fixed sleeps")):
            with self.assertRaisesRegex(AssertionError, "input write timed out"):
                terminal.send(b"pending paste")
        waiter.select.assert_called_once_with(10)
        waiter.close.assert_called_once_with()
        self.assertFalse(terminal._send_pending)
        self.assertEqual(terminal._send_bytes, 0)
        self.assertFalse(terminal._sending)


if __name__ == "__main__":
    unittest.main()
