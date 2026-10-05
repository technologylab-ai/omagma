"""Resize-preserving physical VT cell model for independent repaint evidence."""
from terminal_html_screen import HtmlScreen


class PreservedScreen(HtmlScreen):
    def __init__(self, columns=100, rows=24):
        super().__init__(columns, rows)
        self.full_physical_clears = 0

    def resized(self, columns, rows):
        def grid(old, blank):
            return [(old[y][:columns] + [blank] * max(0, columns-len(old[y]))) if y < len(old)
                    else [blank] * columns for y in range(rows)]
        self.cells = grid(self.cells, " ")
        self.styles = grid(self.styles, self.style)
        if self.main is not None:
            cells, x, y = self.main
            self.main = (grid(cells, " "), min(x, columns-1), min(y, rows-1))
        if self.main_styles is not None: self.main_styles = grid(self.main_styles, self.style)
        self.columns, self.rows = columns, rows
        self.x, self.y = min(self.x, columns-1), min(self.y, rows-1)
        self.top, self.bottom = 0, rows-1
        self.pending_wrap = False
        self.anchor = None

    def csi(self, sequence, final):
        if final == "J" and sequence in ("", "0", "2", "3"):
            if sequence in ("2", "3") or self.x == self.y == 0:
                self.full_physical_clears += 1
        super().csi(sequence, final)


if __name__ == "__main__":
    import unittest

    class PreservingCheck(unittest.TestCase):
        def test_resize_does_not_hide_old_border(self):
            screen = PreservedScreen(225, 40)
            screen.feed("\x1b[11;225H│".encode())
            screen.resized(251, 40)
            self.assertEqual(screen.cells[10][224], "│")
            self.assertEqual(screen.full_physical_clears, 0)
            screen.feed(b"\x1b[H\x1b[J")
            self.assertEqual(screen.cells[10][224], " ")
            self.assertEqual(screen.full_physical_clears, 1)

        def test_paint_only_logical_width_cannot_hide_physical_tail(self):
            screen = PreservedScreen(251, 20)
            screen.feed("\x1b[5;247H│\x1b[5;1H".encode()+b" "*240)
            self.assertEqual(screen.cells[4][246], "│")
            screen.feed(b"\x1b[H\x1b[J")
            self.assertEqual(screen.cells[4][246], " ")

        def test_resize_preserves_style_and_alt_screen(self):
            screen = PreservedScreen(20, 4)
            screen.feed(b"\x1b[31mmain\x1b[?1049h\x1b[1malt")
            screen.resized(30, 8)
            self.assertEqual(screen.lines()[0], "alt")
            self.assertTrue(screen.styles[0][0][2])
            screen.feed(b"\x1b[?1049l")
            self.assertEqual(screen.lines()[0], "main")
            self.assertEqual(screen.styles[0][0][0], ("indexed", 1))

    unittest.main()
