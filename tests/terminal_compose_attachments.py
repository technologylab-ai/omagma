#!/usr/bin/env python3
"""Focused multiple-file composer/reply PTY checks; fixtures only."""
import argparse, base64, hashlib, tempfile
from pathlib import Path
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal, click, point
from terminal_mouse_screen import MouseScreen


def run(binary, directory, key):
    terminal = MouseTerminal(binary, directory, columns=160, rows=40, screen_type=MouseScreen)
    try:
        terminal.until(lambda: terminal.screen.mouse_tracking_mode == 1002)
        terminal.until(lambda: 'From: Fixture account <personal@example.com>' in terminal.text() and 'Ready' in terminal.text())
        if key != b'c':
            terminal.send(b'j')
            terminal.until(lambda: 'From: Alex Fixture <alex@example.org>' in terminal.text() and 'Ready' in terminal.text())
        terminal.send(key)
        terminal.until(lambda: 'Subject:' in terminal.text() and 'Attachments 0' in terminal.text())
        require('A Attach' in terminal.text() and '[Add A]' in terminal.text(), 'attachment shortcut hidden in composer')
        payloads = {name: value for name, value in [('first.txt', b'One\n'), ('second.bin', bytes(range(128))), ('third.pdf', b'%PDF-synthetic\n')]}
        for index, (name, contents) in enumerate(payloads.items()):
            path = directory / name
            path.write_bytes(contents)
            if index == 0: terminal.send(b'A')
            else: click(terminal, *point(terminal, '[Add A]'))
            terminal.until(lambda: 'Attach file path:' in terminal.text())
            terminal.send(str(path).encode() + b'\r')
            terminal.until(lambda: f'Attachments {index + 1}' in terminal.text() and terminal.screen.locate(name) is not None)
            attached_at = terminal.screen.locate(name)
            require(f'{len(contents)} B' in ''.join(terminal.screen.cells[attached_at['row']]),
                    'visible attachment row has the wrong source byte size')
        terminal.gap(.1)
        # Remove only the first file with its explicitly rendered local control.
        at = terminal.screen.locate('first.txt')
        require(at is not None, 'first attachment not visible')
        row = ''.join(terminal.screen.cells[at['row']])
        remove_column = row.index('[x]')
        click(terminal, remove_column + 1, at['row'])
        terminal.until(lambda: 'Attachments 2' in terminal.text() and terminal.screen.locate('first.txt') is None)
        require('first.txt' not in ''.join(terminal.screen.cells[at['row']]), 'removed file remains in composer list')
        terminal.send(b'\x13')
        terminal.until(lambda: 'Sending account:' in terminal.text() and 'Attachment 2: third.pdf' in terminal.text())
        with Client(binary, directory) as client:
            drafts = client.request('draft.list')['drafts']
            require(len(drafts) == 1, 'attachment edits created another draft')
            draft = client.request('draft.read', draftId=drafts[0]['id'])
            require([f['filename'] for f in draft['attachments']] == ['second.bin', 'third.pdf'], 'multiple files not retained after review/save')
            for attachment in draft['attachments']:
                raw = attachment['data']
                decoded = base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4))
                expected = payloads[attachment['filename']]
                require(decoded == expected and attachment['size'] == len(expected), 'attachment bytes or stored size changed')
                require(hashlib.sha256(decoded).digest() == hashlib.sha256(expected).digest(), 'stored attachment hash differs from source payload')
            if key != b'c':
                require(draft['subject'].startswith('Re:') and draft['threadId'], 'reply attachment edit lost threading')
            require(client.request('cache.stats')['fixtureSends'] == 0, 'attachment edit sent mail')
        terminal.send(b'n')
        terminal.until(lambda: 'Compose' in terminal.text() and 'Subject:' in terminal.text())
        terminal.finish()
        print(f'PASS {key.decode()}: three attachments, mouse add/remove, two persisted with exact bytes')
    except Exception:
        print(terminal.text())
        raise
    finally: terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-compose-files-') as temporary:
        for key in (b'c', b'r', b'R'):
            directory = Path(temporary) / key.decode()
            directory.mkdir()
            run(args.binary.resolve(), directory, key)

if __name__ == '__main__': main()
