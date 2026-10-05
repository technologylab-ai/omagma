"""Bounded current-cell help navigation, independent of document line count."""


def scroll_help_to(terminal, literal):
    terminal.until(lambda: "Keys · j/k Scroll · Esc Back" in terminal.text())
    for _ in range(64):
        if literal in terminal.text(): return
        terminal.send(b"j")
        terminal.gap(.02)
    raise AssertionError("complete required help literal was not reachable by scrolling")
