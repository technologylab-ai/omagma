"""Development-only current-cell HTML style oracle; no application dependency."""
from terminal_status_screen import StatusScreen


class HtmlScreen(StatusScreen):
    def __init__(self, columns=100, rows=24):
        super().__init__(columns, rows)
        self.style = (*self.style, False, False, False)  # italic, underline, strike
        self.styles = [[self.style] * columns for _ in range(rows)]

    def sgr(self, sequence):
        italic, underline, strike = self.style[3:]
        self.style = self.style[:3]
        super().sgr(sequence)
        values = []
        try:
            values = [int(f) for f in sequence.replace(":", ";").split(";") if f] if sequence else [0]
        except ValueError:
            pass
        index = 0
        while index < len(values):
            value = values[index]
            index += 1
            if value in (38, 48, 58) and index < len(values):
                mode = values[index]
                index += 1 + (3 if mode == 2 else 1 if mode == 5 else 0)
            elif value == 0:
                italic = underline = strike = False
            elif value == 3:
                italic = True
            elif value == 23:
                italic = False
            elif value == 4:
                underline = True
            elif value == 24:
                underline = False
            elif value == 9:
                strike = True
            elif value == 29:
                strike = False
        self.style = (*self.style, italic, underline, strike)


if __name__ == "__main__":
    import unittest

    class HtmlStyleCheck(unittest.TestCase):
        def test_each_style_and_reset(self):
            screen = HtmlScreen(40, 4)
            screen.feed(b"\x1b[1;3;4;9mRich\x1b[0m Plain")
            self.assertEqual(screen.styles[0][0][2:], (True, True, True, True))
            self.assertEqual(screen.styles[0][5][2:], (False, False, False, False))

        def test_rgb_numbers_are_not_style_commands(self):
            screen = HtmlScreen(40, 4)
            screen.feed(b"\x1b[38;2;3;4;9mColor")
            self.assertEqual(screen.styles[0][0][0], ("rgb", 3, 4, 9))
            self.assertEqual(screen.styles[0][0][3:], (False, False, False))

        def test_overwritten_text_has_current_style(self):
            screen = HtmlScreen(40, 4)
            screen.feed(b"\x1b[3;4mOld\r\x1b[23;24mNew")
            self.assertEqual(screen.styles[0][0][3:], (False, False, False))

    unittest.main()
