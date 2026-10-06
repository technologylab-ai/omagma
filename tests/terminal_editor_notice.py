#!/usr/bin/env python3
"""Editor action outcomes survive a preempted real recipient fetch in owned PTYs."""
import argparse
import json
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, Client, require
from terminal_recipient_preview import prepare, begin


def exercise(binary, directory, action):
    source, extra = prepare(binary, directory)
    terminal = begin(binary, directory, extra)
    hold, entered = source.root / 'editor-recipients.hold', source.root / 'editor-recipients.entered'
    try:
        data = json.loads(source.path(ACCOUNTS[0]).read_text())
        hold.write_text('Owned fictional metadata hold\n')
        data['sync']['fixtureProgress'] = {'phase': 'metadata', 'completed': 1,
            'fixtureHold': hold.name, 'fixtureEntered': entered.name}
        source.path(ACCOUNTS[0]).write_text(json.dumps(data))
        terminal.send(b'c')
        terminal.until(lambda: 'Draft preview' in terminal.text() and entered.exists())
        terminal.send(b'e')
        terminal.until(lambda: terminal.editor_log.exists())
        require(hold.exists(), 'recipient fixture finished before editor preemption')
        editor = json.loads(terminal.editor_log.read_text())
        require(editor['stdinIsTty'] and editor['stdoutIsTty'] and editor['fileExists'],
                'editor takeover did not have its owned draft and controlling PTY')
        terminal.send({'save': b's', 'cancel': b'x', 'save-error': b'r'}[action])
        expected_notice = 'Editor returned' if action == 'save' else 'Editor exited 1'
        terminal.until(lambda: 'exitCode' in json.loads(terminal.editor_log.read_text())
                       and 'Compose' in terminal.text() and expected_notice in terminal.text())
        terminal.gap(.2)
        require(expected_notice in terminal.text(), 'background completion cleared the editor action outcome')
        expected_body = 'Reviewed fixture editor body.\nCafé and emoji 👋 remain intact.\n' if action != 'cancel' else ''
        with Client(binary, directory, extra=extra) as client:
            drafts = client.request('draft.list')['drafts']
            require(len(drafts) == 1, 'editor result created or lost a local draft')
            draft = client.request('draft.read', draftId=drafts[0]['id'])
            require(draft['bodyText'] == expected_body, 'editor notice changed the retained draft body')
            require(client.request('cache.stats')['fixtureSends'] == 0, 'editor result sent mail')
        result = terminal.finish()
        require(result['termiosRestored'] and result['exitCode'] == 0, 'editor notice run did not restore its terminal')
        print(f'PASS editor notice: {action}, held recipient fetch preempted, outcome visible, exact draft/no-send/TTY restored')
    except Exception:
        print(terminal.text())  # Only owned fictional fixture cells.
        raise
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--case', choices=['all', 'save', 'cancel', 'save-error'], default='all')
    args = parser.parse_args()
    for action in ('save', 'cancel', 'save-error'):
        if args.case not in ('all', action):
            continue
        with tempfile.TemporaryDirectory(prefix='omagma-editor-notice-') as directory:
            exercise(args.binary.resolve(), Path(directory), action)


if __name__ == '__main__':
    main()
