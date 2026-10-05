"""Small development-only VT cell model for controlled PTY rendering checks."""
import codecs
import unicodedata


class Screen:
    def __init__(self, columns=100, rows=24):
        self.columns, self.rows = columns, rows
        self.cells = [[" "] * columns for _ in range(rows)]
        self.x = self.y = 0
        self.saved = (0, 0)
        self.main = None
        self.top, self.bottom = 0, rows - 1
        self.wrap = True
        self.pending_wrap = False
        self.state, self.sequence = "ground", ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.anchor = None
        self.join_next = False
        self.wide_right_edge = 0

    def feed(self, data):
        for char in self.decoder.decode(data):
            if self.state == "osc":
                if char == "\x07": self.state = "ground"
                elif char == "\x1b": self.state = "osc-escape"
                continue
            if self.state in {"osc-escape", "dcs-escape"}:
                self.state = "ground" if char == "\\" else ("osc" if self.state == "osc-escape" else "dcs")
                continue
            if self.state == "dcs":
                if char == "\x1b": self.state = "dcs-escape"
                continue
            if self.state == "escape":
                self.state = "ground"
                if char == "[": self.state, self.sequence = "csi", ""
                elif char == "]": self.state = "osc"
                elif char in {"P", "^", "_"}: self.state = "dcs"
                elif char == "7": self.saved = (self.x, self.y)
                elif char == "8": self.x, self.y = self.saved
                elif char == "D": self.linefeed()
                elif char == "E": self.x = 0; self.linefeed()
                elif char == "M": self.reverse_index()
                elif char == "c": self.clear(); self.x = self.y = 0
                elif char in {"(", ")", "*", "+", "#", "%"}: self.state = "charset"
                continue
            if self.state == "charset":
                self.state = "ground"
                continue
            if self.state == "csi":
                if "@" <= char <= "~":
                    self.csi(self.sequence, char)
                    self.state, self.sequence = "ground", ""
                else:
                    self.sequence += char
                continue
            if char == "\x1b": self.state = "escape"
            elif char == "\r": self.x = 0; self.pending_wrap = False
            elif char in {"\n", "\v", "\f"}: self.linefeed()
            elif char == "\b": self.x = max(0, self.x - 1); self.pending_wrap = False
            elif char == "\t": self.x = min(self.columns - 1, (self.x // 8 + 1) * 8); self.pending_wrap = False
            elif ord(char) >= 32 and char != "\x7f": self.draw(char)

    def clear(self):
        self.cells = [[" "] * self.columns for _ in range(self.rows)]
        self.anchor = None

    def linefeed(self):
        self.pending_wrap = False
        if self.y == self.bottom:
            del self.cells[self.top]
            self.cells.insert(self.bottom, [" "] * self.columns)
        else:
            self.y = min(self.rows - 1, self.y + 1)

    def reverse_index(self):
        self.pending_wrap = False
        if self.y == self.top:
            del self.cells[self.bottom]
            self.cells.insert(self.top, [" "] * self.columns)
        else:
            self.y = max(0, self.y - 1)

    def draw(self, char):
        if char == "\u200d" or unicodedata.combining(char) or char in {"\ufe0e", "\ufe0f"} or self.join_next:
            if self.anchor:
                y, x = self.anchor
                self.cells[y][x] += char
            self.join_next = char == "\u200d"
            return
        width = 2 if unicodedata.east_asian_width(char) in {"W", "F"} else 1
        if self.pending_wrap:
            if self.wrap: self.x = 0; self.linefeed()
            self.pending_wrap = False
        if width == 2 and self.x == self.columns - 1:
            self.wide_right_edge += 1
            if self.wrap: self.x = 0; self.linefeed()
            else: return
        self.cells[self.y][self.x] = char
        self.anchor = (self.y, self.x)
        if width == 2: self.cells[self.y][self.x + 1] = ""
        self.x += width
        if self.x >= self.columns:
            self.x = self.columns - 1
            self.pending_wrap = True

    def csi(self, sequence, final):
        private = sequence.startswith("?")
        clean = sequence.lstrip("?><!")
        try: values = [int(v) if v else 0 for v in clean.split(";")]
        except ValueError: return
        n = values[0] or 1
        if final in {"H", "f"}:
            self.y = min(self.rows - 1, max(0, n - 1))
            self.x = min(self.columns - 1, max(0, (values[1] if len(values) > 1 and values[1] else 1) - 1))
        elif final == "G": self.x = min(self.columns - 1, n - 1)
        elif final == "d": self.y = min(self.rows - 1, n - 1)
        elif final == "A": self.y = max(0, self.y - n)
        elif final in {"B", "e"}: self.y = min(self.rows - 1, self.y + n)
        elif final in {"C", "a"}: self.x = min(self.columns - 1, self.x + n)
        elif final == "D": self.x = max(0, self.x - n)
        elif final == "E": self.y = min(self.rows - 1, self.y + n); self.x = 0
        elif final == "F": self.y = max(0, self.y - n); self.x = 0
        elif final == "J":
            mode = values[0]
            if mode in {2, 3}: self.clear()
            elif mode == 0:
                self.cells[self.y][self.x:] = [" "] * (self.columns - self.x)
                for y in range(self.y + 1, self.rows): self.cells[y] = [" "] * self.columns
            elif mode == 1:
                for y in range(self.y): self.cells[y] = [" "] * self.columns
                self.cells[self.y][:self.x + 1] = [" "] * (self.x + 1)
        elif final == "K":
            mode = values[0]
            start, end = (0, self.columns) if mode == 2 else ((0, self.x + 1) if mode == 1 else (self.x, self.columns))
            self.cells[self.y][start:end] = [" "] * (end - start)
        elif final == "X":
            end = min(self.columns, self.x + n)
            self.cells[self.y][self.x:end] = [" "] * (end - self.x)
        elif final == "P": self.cells[self.y][self.x:] = (self.cells[self.y][self.x + n:] + [" "] * n)[:self.columns - self.x]
        elif final == "@": self.cells[self.y][self.x:] = ([" "] * n + self.cells[self.y][self.x:])[:self.columns - self.x]
        elif final == "s": self.saved = (self.x, self.y)
        elif final == "u": self.x, self.y = self.saved
        elif final == "r" and not private:
            self.top = min(self.rows - 1, max(0, n - 1))
            self.bottom = min(self.rows - 1, (values[1] or self.rows) - 1) if len(values) > 1 else self.rows - 1
            self.x = self.y = 0
        elif final in {"h", "l"} and private:
            for mode in values:
                if mode == 7: self.wrap = final == "h"
                if mode in {47, 1047, 1049}:
                    if final == "h" and self.main is None:
                        self.main = (self.cells, self.x, self.y)
                        self.clear(); self.x = self.y = 0
                    elif final == "l" and self.main is not None:
                        self.cells, self.x, self.y = self.main
                        self.main = None
        self.pending_wrap = False

    def lines(self):
        return ["".join(row).rstrip() for row in self.cells]

    def text(self):
        return "\n".join(self.lines())

    def locate(self, text):
        for y, row in enumerate(self.cells):
            for x in range(self.columns):
                if row[x] and "".join(row[x:]).startswith(text):
                    return {"row": y, "column": x}
        return None


if __name__ == "__main__":
    import unittest

    class ScreenCheck(unittest.TestCase):
        def test_overwritten_text_is_removed(self):
            screen = Screen(10, 3)
            screen.feed(b"old value\r\x1b[Knew")
            self.assertEqual(screen.lines()[0], "new")
            self.assertNotIn("old", screen.text())

        def test_cursor_moves_place_labels(self):
            screen = Screen(20, 4)
            screen.feed(b"\x1b[3;8HSubject:")
            self.assertEqual(screen.locate("Subject:"), {"row": 2, "column": 7})

        def test_utf8_combining_and_wide_cells(self):
            screen = Screen(12, 3)
            for block in [b"Cafe\xcc", b"\x81 ", "👋".encode(), b"X"]: screen.feed(block)
            self.assertEqual(screen.cells[0][3], "e\u0301")
            self.assertEqual(screen.cells[0][5], "👋")
            self.assertEqual(screen.cells[0][6], "")
            self.assertEqual(screen.locate("X"), {"row": 0, "column": 7})

        def test_alternate_screen_restores_main(self):
            screen = Screen(12, 3)
            screen.feed(b"main\x1b[?1049halt\x1b[?1049l")
            self.assertEqual(screen.lines()[0], "main")

        def test_osc_does_not_become_cells(self):
            screen = Screen(20, 3)
            screen.feed(b"safe\x1b]52;c;ZmFrZQ==\x07text")
            self.assertEqual(screen.lines()[0], "safetext")

        def test_clear_removes_prior_frame(self):
            screen = Screen(20, 3)
            screen.feed(b"old\x1b[2J\x1b[1;1Hnew")
            self.assertEqual(screen.text(), "new\n\n")

    unittest.main()
