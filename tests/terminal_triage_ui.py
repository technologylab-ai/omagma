#!/usr/bin/env python3
"""Fixture-only bulk/undo, custom-label views and cache body search PTY checks."""
import argparse, tempfile
from pathlib import Path
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal, click
from terminal_mouse_screen import MouseScreen
from terminal_dialog_controls import activate, filter_label_picker, reach, wait_label_picker


def sidebar_point(terminal, literal):
    title = terminal.screen.locate('Accounts / mailboxes')
    require(title is not None, 'sidebar pane is not visible')
    border = terminal.screen.cells[title['row']]
    right = next(column for column in range(title['column'], terminal.columns)
                 if border[column] in {'╮', '┐', '╗'})
    for row in range(title['row'] + 1, terminal.rows - 2):
        for column in range(1, right):
            if ''.join(terminal.screen.cells[row][column:right]).startswith(literal):
                return column, row
    require(False, f'expected sidebar target is absent: {literal}')


def check(binary, directory):
    terminal = MouseTerminal(binary, directory, columns=160, rows=40, screen_type=MouseScreen,
                             environment={"COLORTERM": "truecolor", "NO_COLOR": None})
    try:
        terminal.until(lambda: terminal.screen.mouse_tracking_mode == 1002)
        terminal.until(lambda: 'From: Fixture account <personal@example.com>' in terminal.text() and 'Ready' in terminal.text())
        terminal.until(lambda: terminal.screen.locate('Projects') is not None)
        with Client(binary, directory) as client:
            before = {m['id']: set(m['labels']) for m in client.request('mail.list', cacheOnly=True, limit=100)['messages']}
        terminal.send(b'  ')
        terminal.until(lambda: '2 selected' in terminal.text() and terminal.text().count('✓') >= 2)
        terminal.send(b'x')
        terminal.until(lambda: 'Mail action:' in terminal.text())
        with Client(binary, directory) as client:
            after = {m['id']: set(m['labels']) for m in client.request('mail.list', cacheOnly=True, limit=100)['messages']}
            changed = [identifier for identifier, labels in before.items() if after.get(identifier) != labels]
            require(len(changed) == 2 and all('INBOX' not in after[m] for m in changed), 'bulk archive changed wrong IDs')
        terminal.send(b':undo\r')
        terminal.until(lambda: 'Undo:' in terminal.text())
        with Client(binary, directory) as client:
            restored = {m['id']: set(m['labels']) for m in client.request('mail.list', cacheOnly=True, limit=100)['messages']}
            require(all(restored[m] == before[m] for m in changed), 'TUI undo did not restore exact previous labels')
        terminal.send(b'm')
        wait_label_picker(terminal, '[ ]  Projects')
        filter_label_picker(terminal, 'Projects', '[ ]')
        terminal.send(b'\r')
        terminal.until(lambda: '[Apply 1]' in terminal.text())
        with Client(binary, directory) as client:
            staged = {m['id']: set(m['labels']) for m in client.request('mail.list', cacheOnly=True, limit=100)['messages']}
            require(staged == restored, 'staging a label changed mail before Apply')
        reach(terminal, '[Apply 1]')
        activate(terminal)
        terminal.until(lambda: 'Mail action:' in terminal.text() and 'Labels · staged changes' not in terminal.text())
        click(terminal, *sidebar_point(terminal, 'Projects'))
        terminal.until(lambda: 'Projects' in terminal.text().splitlines()[0]
                       and 'Synthetic personal' in terminal.text())
        require('Synthetic personal' in terminal.text(), 'custom-label view failed to show tagged mail')
        click(terminal, *sidebar_point(terminal, 'Unread'))
        terminal.until(lambda: 'Unread' in terminal.text().splitlines()[0])
        with Client(binary, directory) as client:
            require(client.request('cache.stats')['fixtureSends'] == 0, 'triage UI submitted mail')
        click(terminal, *sidebar_point(terminal, 'All Mail'))
        terminal.until(lambda: 'All Mail' in terminal.text().splitlines()[0])
        terminal.send(b'/body:"fixture team"\r')
        terminal.until(lambda: 'Cache search' in terminal.screen.lines()[0] and 'Olá' in terminal.text())
        terminal.send(b'q')
        terminal.until(lambda: 'Cache search' not in terminal.text().splitlines()[0])
        terminal.finish()
        print('PASS bulk selected archive/exact undo, name label chooser/custom view, Unread/All Mail, cached body search')
    except Exception:
        print(terminal.text())
        raise
    finally: terminal.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-triage-ui-') as temporary:
        check(args.binary.resolve(),Path(temporary))

if __name__=='__main__': main()
