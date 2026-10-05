"""Development-only SGR cell styles for independent TUI status-color checks."""
from terminal_screen import Screen


class StatusScreen(Screen):
    def __init__(self, columns=100, rows=24):
        self.style = (None, None, False)  # foreground, background, bold
        self.main_styles = None
        super().__init__(columns, rows)
        self.styles = [[self.style] * columns for _ in range(rows)]

    def clear(self):
        super().clear()
        self.styles = [[self.style] * self.columns for _ in range(self.rows)]

    def linefeed(self):
        if self.y == self.bottom:
            del self.styles[self.top]
            self.styles.insert(self.bottom, [self.style] * self.columns)
        super().linefeed()

    def reverse_index(self):
        if self.y == self.top:
            del self.styles[self.bottom]
            self.styles.insert(self.top, [self.style] * self.columns)
        super().reverse_index()

    def draw(self, char):
        previous = self.anchor
        super().draw(char)
        if self.anchor is None:
            return
        y, x = self.anchor
        # Combining marks keep the style of their existing base cell.
        if self.anchor != previous or self.cells[y][x] == char:
            self.styles[y][x] = self.style
            if x + 1 < self.columns and self.cells[y][x + 1] == "":
                self.styles[y][x + 1] = self.style

    def sgr(self, sequence):
        # Accept both semicolon and ISO colon true-color forms emitted by VT
        # renderers.  No status text is inferred from historical raw output.
        fields = sequence.replace(":", ";").split(";") if sequence else ["0"]
        try:
            values = [int(field) for field in fields if field]
        except ValueError:
            return
        fg, bg, bold = self.style
        index = 0
        while index < len(values):
            value = values[index]
            index += 1
            if value == 0:
                fg, bg, bold = None, None, False
            elif value == 1:
                bold = True
            elif value == 22:
                bold = False
            elif value in (39, 49):
                if value == 39: fg = None
                else: bg = None
            elif 30 <= value <= 37 or 90 <= value <= 97:
                fg = ("indexed", value - 30 if value < 90 else value - 90 + 8)
            elif 40 <= value <= 47 or 100 <= value <= 107:
                bg = ("indexed", value - 40 if value < 100 else value - 100 + 8)
            elif value in (38, 48) and index < len(values):
                mode = values[index]
                index += 1
                color = None
                if mode == 2 and index + 3 <= len(values):
                    color = ("rgb", *values[index:index + 3])
                    index += 3
                elif mode == 5 and index < len(values):
                    color = ("indexed", values[index])
                    index += 1
                if color is not None:
                    if value == 38: fg = color
                    else: bg = color
        self.style = (fg, bg, bold)

    def csi(self, sequence, final):
        if final == "m":
            self.sgr(sequence)
            return
        private = sequence.startswith("?")
        try:
            values = [int(value) if value else 0 for value in sequence.lstrip("?><!").split(";")]
        except ValueError:
            values = []
        n = (values[0] or 1) if values else 1
        if final == "J" and values:
            mode = values[0]
            if mode == 0:
                self.styles[self.y][self.x:] = [self.style] * (self.columns - self.x)
                for y in range(self.y + 1, self.rows): self.styles[y] = [self.style] * self.columns
            elif mode == 1:
                for y in range(self.y): self.styles[y] = [self.style] * self.columns
                self.styles[self.y][:self.x + 1] = [self.style] * (self.x + 1)
        elif final == "K" and values:
            mode = values[0]
            start, end = (0, self.columns) if mode == 2 else ((0, self.x + 1) if mode == 1 else (self.x, self.columns))
            self.styles[self.y][start:end] = [self.style] * (end - start)
        elif final == "X":
            end = min(self.columns, self.x + n)
            self.styles[self.y][self.x:end] = [self.style] * (end - self.x)
        elif final == "P":
            self.styles[self.y][self.x:] = (self.styles[self.y][self.x + n:] + [self.style] * n)[:self.columns - self.x]
        elif final == "@":
            self.styles[self.y][self.x:] = ([self.style] * n + self.styles[self.y][self.x:])[:self.columns - self.x]
        if private and final in ("h", "l") and any(v in (47, 1047, 1049) for v in values):
            if final == "h" and self.main is None:
                self.main_styles = self.styles
            elif final == "l" and self.main is not None:
                restored = self.main_styles
                super().csi(sequence, final)
                self.styles, self.main_styles = restored, None
                return
        super().csi(sequence, final)

    def foregrounds(self, text):
        location = self.locate(text)
        if location is None:
            return None
        y, x = location["row"], location["column"]
        return {self.styles[y][column][0] for column in range(x, min(self.columns, x + len(text)))}


if __name__ == "__main__":
    import unittest

    class StyleCheck(unittest.TestCase):
        def test_fragmented_rgb(self):
            screen = StatusScreen(40, 3)
            for block in (b"\x1b[38;2;92;", b"177;255mFetching mail", b"\x1b[0m"):
                screen.feed(block)
            self.assertEqual(screen.foregrounds("Fetching mail"), {("rgb", 92, 177, 255)})
            self.assertEqual(screen.style, (None, None, False))

        def test_overwritten_style_uses_current_cells(self):
            screen = StatusScreen(40, 3)
            screen.feed(b"\x1b[31mold status\r\x1b[K\x1b[38:2::133:207:149mUp to date")
            self.assertIsNone(screen.foregrounds("old status"))
            self.assertEqual(screen.foregrounds("Up to date"), {("rgb", 133, 207, 149)})

        def test_alternate_and_scroll_preserve_style(self):
            screen = StatusScreen(40, 3)
            screen.feed(b"\x1b[33mOffline cached mail\x1b[?1049h\x1b[34mFetching mail\x1b[?1049l")
            self.assertEqual(screen.foregrounds("Offline cached mail"), {("indexed", 3)})
            screen.feed(b"\x1b[3;1H\n")
            self.assertIsNone(screen.foregrounds("Offline cached mail"))

    unittest.main()
