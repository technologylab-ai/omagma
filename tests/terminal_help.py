"""Bounded current-cell help navigation, independent of document line count."""


def help_viewport(terminal):
    """Observe the help panel alone, excluding unrelated background updates."""
    title = terminal.screen.locate("Keyboard & mouse")
    if title is None:
        return None
    cells = terminal.screen.cells
    top = title["row"]
    left = next((i for i in range(title["column"], -1, -1) if cells[top][i] in "╭┌"), None)
    right = next((i for i in range(title["column"], terminal.columns) if cells[top][i] in "╮┐"), None)
    if left is None or right is None:
        return None
    bottom = next((i for i in range(top + 1, terminal.rows)
                   if cells[i][left] in "╰└" and cells[i][right] in "╯┘"), None)
    if bottom is None:
        return None
    return "\n".join("".join(row[left + 1:right]) for row in cells[top + 1:bottom])


def scroll_help_to(terminal, literal):
    terminal.until(lambda: help_viewport(terminal) is not None)
    for _ in range(160):
        before = help_viewport(terminal)
        if literal in before:
            return
        terminal.send(b"j")
        # A fixed gap may leave a synchronized redraw half-read. Observe one
        # completed viewport change before sending another scroll key.
        try:
            terminal.until(lambda: help_viewport(terminal) not in (None, before), seconds=3)
        except AssertionError as error:
            raise AssertionError(f"help scrolling stopped before required literal: {literal}") from error
    if literal not in help_viewport(terminal):
        raise AssertionError(f"complete required help literal was not reachable by 160 observed scrolls: {literal}")
