"""Development-only extraction of current reader cells, excluding other panes."""


def reader_rectangle(screen):
    title = screen.locate("Thread / full body") or screen.locate("Message ·")
    if title is None:
        return None
    y, column = title["row"], title["column"]
    row = screen.cells[y]
    left = next((x for x in range(column, -1, -1) if row[x] in {"╭", "┌", "╔"}), None)
    right = next((x for x in range(column, screen.columns) if row[x] in {"╮", "┐", "╗"}), None)
    if left is None or right is None or left >= right:
        return None
    bottom = next((index for index in range(y + 1, screen.rows)
                   if screen.cells[index][left] in {"╰", "└", "╚"} and screen.cells[index][right] in {"╯", "┘", "╝"}), None)
    if bottom is None:
        return None
    return {"left": left + 1, "right": right, "top": y + 1, "bottom": bottom}


def reader_rows(screen):
    rectangle = reader_rectangle(screen)
    if rectangle is None:
        return []
    return [(y, "".join(screen.cells[y][rectangle["left"]:rectangle["right"]]).rstrip())
            for y in range(rectangle["top"], rectangle["bottom"])]


def reader_contains(screen, literal):
    # Whitespace-independent comparison rejoins soft wraps of the full literal.
    # It does not use historical VT output, neighboring list text or shortened
    # account/message identity substrings.
    joined = "".join("".join(text.split()) for _, text in reader_rows(screen))
    return "".join(literal.split()) in joined


if __name__ == "__main__":
    import unittest
    from terminal_screen import Screen

    class ReaderCheck(unittest.TestCase):
        def make(self, lines, width=100):
            screen = Screen(width, len(lines))
            for y, text in enumerate(lines):
                screen.feed(f"\x1b[{y + 1};1H".encode() + text.encode())
            return screen

        def test_right_wrapped_identity_excludes_list(self):
            def top(width, title):
                return "╭" + ("─ " + title + " ").ljust(width - 2, "─") + "╮"
            def bottom(width):
                return "╰" + "─" * (width - 2) + "╯"
            def line(width, text):
                return "│" + text.ljust(width - 2) + "│"
            left = line(55, "Synthetic other@example.org message095; noise")
            screen = self.make([
                top(55, "Mail") + top(45, "Thread / full body"),
                left + line(45, "Synthetic personal@example.com message09"),
                left + line(45, "6."),
                bottom(55) + bottom(45),
            ])
            self.assertTrue(reader_contains(screen, "Synthetic personal@example.com message096."))
            self.assertFalse(reader_contains(screen, "Synthetic other@example.org message095."))

        def test_below_layout(self):
            screen = self.make([
                "╭─ Mail ────────────────────────────────────────────╮",
                "│Synthetic list only                               │",
                "╰───────────────────────────────────────────────────╯",
                "╭─ Thread / full body ──────────────────────────────╮",
                "│Synthetic personal@example.com message              │",
                "│096.                                                │",
                "╰───────────────────────────────────────────────────╯",
            ], 53)
            self.assertTrue(reader_contains(screen, "Synthetic personal@example.com message096."))

        def test_wrong_account_and_message_refused(self):
            screen = self.make([
                "╭─ Thread / full body ──────────────────────────────╮",
                "│Synthetic work@example.com message096.              │",
                "╰───────────────────────────────────────────────────╯",
            ], 53)
            self.assertFalse(reader_contains(screen, "Synthetic personal@example.com message096."))
            self.assertFalse(reader_contains(screen, "Synthetic work@example.com message095."))

        def test_metadata_snippet_does_not_prove_full_body(self):
            screen = self.make([
                "╭─ Thread / full body ──────────────────────────────╮",
                "│Body not cached                                    │",
                "│Synthetic personal message096; snippet only        │",
                "╰───────────────────────────────────────────────────╯",
            ], 53)
            self.assertFalse(reader_contains(screen, "Synthetic personal@example.com message096."))

        def test_no_reader_never_uses_global_text(self):
            screen = self.make(["Synthetic personal@example.com message096."])
            self.assertFalse(reader_contains(screen, "Synthetic personal@example.com message096."))

    unittest.main()
