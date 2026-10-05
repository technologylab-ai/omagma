"""Current VT mouse-mode oracle for an owned synthetic terminal."""
from terminal_repaint_screen import PreservedScreen

MOUSE_MODES = {1000, 1002, 1003, 1004, 1006, 1016}


class MouseScreen(PreservedScreen):
    def __init__(self, columns=100, rows=24):
        super().__init__(columns, rows)
        self.mouse_modes = set()
        self.mouse_history = []

    def csi(self, sequence, final):
        if sequence.startswith("?") and final in ("h", "l"):
            try: modes = [int(value) for value in sequence[1:].split(";")]
            except ValueError: modes = []
            for mode in modes:
                if mode not in MOUSE_MODES: continue
                if final == "h": self.mouse_modes.add(mode)
                else: self.mouse_modes.discard(mode)
                self.mouse_history.append((mode, final == "h"))
                if len(self.mouse_history) > 128: del self.mouse_history[:-128]
        super().csi(sequence, final)


if __name__ == "__main__":
    import unittest

    class ModeCheck(unittest.TestCase):
        def test_compound_modes_then_idle_motion_disable(self):
            screen = MouseScreen()
            screen.feed(b"\x1b[?1002;1003;1004;1006h\x1b[?1003l")
            self.assertEqual(screen.mouse_modes, {1002, 1004, 1006})

        def test_editor_disable_restore_then_exit(self):
            screen = MouseScreen()
            screen.feed(b"\x1b[?1002;1004;1006h\x1b[?1002;1003;1004;1006;1016l")
            self.assertEqual(screen.mouse_modes, set())
            screen.feed(b"\x1b[?1002;1004;1006h")
            self.assertEqual(screen.mouse_modes, {1002, 1004, 1006})
            screen.feed(b"\x1b[?1002;1003;1004;1006;1016l")
            self.assertEqual(screen.mouse_modes, set())

        def test_pixel_mode_would_be_detected(self):
            screen = MouseScreen()
            screen.feed(b"\x1b[?1016h")
            self.assertIn(1016, screen.mouse_modes)

    unittest.main()
