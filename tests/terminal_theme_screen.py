#!/usr/bin/env python3
"""Hand-authored VT reverse-cell oracle checks; no process or GUI is started."""
import unittest

from terminal_calendar_tui import CalendarScreen
from terminal_theme_picker import ThemeScreen


class ReverseCellChecks(unittest.TestCase):
    def test_resize_then_erase_display_from_cursor_resets_only_physical_tail(self):
        for screen_type in (ThemeScreen, CalendarScreen):
            with self.subTest(screen=screen_type.__name__):
                screen = screen_type(8, 3)
                screen.feed(b"\x1b[7m\x1b[2J\x1b[2;1HOLD FOCUS")
                screen.feed(b"\x1b[0m")
                screen.resized(10, 4)
                screen.feed(b"\x1b[2;4H\x1b[J")
                self.assertEqual(screen.reversed, [
                    [True] * 8 + [False] * 2,
                    [True] * 3 + [False] * 7,
                    [False] * 10,
                    [False] * 10,
                ])
                self.assertEqual(screen.lines()[1], "OLD")
                self.assertFalse(any(screen.reversed[2]))

    def test_erase_display_to_cursor_is_inclusive_and_retains_following_cells(self):
        screen = ThemeScreen(6, 3)
        screen.feed(b"\x1b[7m\x1b[2J\x1b[2;1Habcdef\x1b[0m\x1b[2;3H\x1b[1J")
        self.assertEqual(screen.reversed, [[False] * 6, [False] * 3 + [True] * 3, [True] * 6])
        self.assertEqual(screen.lines()[1], "   def")

    def test_partial_and_full_line_erase_use_current_reverse_state(self):
        for mode, expected in ((0, [True, True, False, False, False, False]),
                               (1, [False, False, False, True, True, True]),
                               (2, [False] * 6)):
            for erased_reverse in (False, True):
                with self.subTest(mode=mode, reverse=erased_reverse):
                    screen = ThemeScreen(6, 2)
                    initial = b"\x1b[0m" if erased_reverse else b"\x1b[7m"
                    erase = b"\x1b[7m" if erased_reverse else b"\x1b[27m"
                    screen.feed(initial + b"abcdef" + erase + b"\x1b[1;3H" + f"\x1b[{mode}K".encode())
                    self.assertEqual(screen.reversed[0], [not value for value in expected] if erased_reverse else expected)

    def test_erase_characters_default_and_clipped_count(self):
        screen = ThemeScreen(6, 2)
        screen.feed(b"\x1b[7mabcdef\x1b[0m\x1b[1;2H\x1b[X")
        self.assertEqual(screen.reversed[0], [True, False, True, True, True, True])
        self.assertEqual(screen.lines()[0], "a cdef")
        screen.feed(b"\x1b[1;5H\x1b[99X")
        self.assertEqual(screen.reversed[0], [True, False, True, True, False, False])
        self.assertEqual(screen.lines()[0], "a cd")

    def test_delete_and_insert_shift_existing_reverse_cells(self):
        for command, expected_text, expected in (
            (b"\x1b[1;2H\x1b[3P", "AEFGH", [True, True, True, False, False, False, False, False]),
            (b"\x1b[1;3H\x1b[2@", "AB  CDEF", [True, True, False, False, False, False, True, True]),
        ):
            with self.subTest(command=command):
                screen = ThemeScreen(8, 2)
                screen.feed(b"\x1b[7mAB\x1b[0mCD\x1b[7mEF\x1b[0mGH" + command)
                self.assertEqual(screen.lines()[0], expected_text)
                self.assertEqual(screen.reversed[0], expected)

    def test_full_display_clear_uses_current_sgr_for_blank_cells(self):
        for mode in (2, 3):
            screen = ThemeScreen(8, 3)
            screen.feed(b"\x1b[7mold\x1b[0m" + f"\x1b[{mode}J".encode())
            self.assertEqual(screen.reversed, [[False] * 8 for _ in range(3)])
            screen.feed(b"\x1b[7m" + f"\x1b[{mode}J".encode())
            self.assertEqual(screen.reversed, [[True] * 8 for _ in range(3)])

    def test_calendar_mro_keeps_synchronized_frames_and_sgr_planes(self):
        screen = CalendarScreen(8, 3)
        screen.feed(b"\x1b[?2026h\x1b[7mselected\x1b[0m\x1b[?2026l")
        self.assertEqual(screen.completed_frames, 1)
        self.assertFalse(screen.frame_open)
        screen.resized(10, 4)
        screen.feed(b"\x1b[?2026h\x1b[1;1H\x1b[0Knormal\x1b[?2026l")
        self.assertEqual(screen.completed_frames, 2)
        self.assertFalse(screen.frame_open)
        self.assertEqual(screen.lines()[0], "normal")
        self.assertEqual(screen.reversed[0], [False] * 10)
        self.assertEqual(screen.styles[0], [screen.style] * 10)


if __name__ == "__main__":
    unittest.main()
