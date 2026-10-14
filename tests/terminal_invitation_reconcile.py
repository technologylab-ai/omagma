#!/usr/bin/env python3
"""Resolve a lost RSVP receipt only from positive Sent proof, without resending."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_calendar import Invitations
from terminal_html import screen_capture
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen


def scenario(binary, directory, applied, captures):
    fixture = Invitations(directory)
    options = fixture.options()
    behavior = 'applied-lost' if applied else 'unknown-send'
    client_dir = directory / 'client'
    params = dict(messageId='calendar-mail-4', status='accepted', operationId='reviewed-accept')
    with Client(binary, client_dir, scenario=behavior, extra=options) as client:
        inspected = client.request('invitation.inspect', messageId=params['messageId'])
        params.update(attendee=inspected['attendee'], sourceHash=inspected['sourceHash'])
        receipt = client.request('invitation.reply', **params)
        require(receipt['outcome'] == 'unknown', 'fixture did not lose the submission receipt')
        client.restart()
        repeated = client.request('invitation.reply', **params)
        require(repeated['id'] == receipt['id'] and repeated['outcome'] == 'unknown', 'same operation did not return its durable receipt')
        client.request('invitation.reply', ok=False, **{**params, 'status': 'declined'})
        client.request('invitation.reply', ok=False, **{**params, 'operationId': 'new-id-cannot-bypass'})
        status = client.request('invitation.inspect', messageId=params['messageId'], cacheOnly=True)
        require(status['responseOutcome'] == 'unknown', 'inspection lost uncertain state')
        client.request('invitation.inspect', messageId=params['messageId'], cacheOnly=True, reconcile=True, ok=False)
        require(client.request('cache.stats')['fixtureSends'] == int(applied), 'receipt retry resubmitted the RSVP')
    if applied:
        terminal = MouseTerminal(binary, client_dir, extra=(*options, '--fixture-scenario', behavior),
                                 screen_type=MouseScreen, columns=120, rows=35, environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "Europe/Vienna"})
        try:
            terminal.until(lambda: 'Up to date' in terminal.text())
            terminal.send(b'/subject:"Planning version 4"\r')
            terminal.until(lambda: 'Planning version 4' in terminal.text())
            terminal.gap(.3)
            terminal.send(b'I')
            terminal.until(lambda: '[C Check Sent]' in terminal.text())
            terminal.send(b'atd')
            terminal.gap(.1)
            require('Meeting' in terminal.text(), 'unknown RSVP allowed a second response')
            if captures:
                captures.mkdir(parents=True, exist_ok=True)
                (captures / 'rsvp-unknown.json').write_text(json.dumps(screen_capture(terminal)) + '\n')
            terminal.send(b'C')
            terminal.until(lambda: 'Your confirmed RSVP: ACCEPTED' in terminal.text())
            require('[C Check Sent]' not in terminal.text(), 'confirmed receipt still has unresolved action')
            if captures:
                (captures / 'rsvp-reconciled.json').write_text(json.dumps(screen_capture(terminal)) + '\n')
            terminal.send(b'\x1b')
            terminal.finish(expected_sends=1)
        except Exception:
            print(terminal.text())
            raise
        finally:
            terminal.close()
    with Client(binary, client_dir, scenario=behavior, extra=options) as client:
        for _ in range(2):
            result = client.request('invitation.inspect', messageId=params['messageId'], reconcile=True)
            require(result['responseOutcome'] == ('applied' if applied else 'unknown'), 'Sent check invented or lost confirmation')
            require(result['confirmedResponse'] == ('ACCEPTED' if applied else ''), 'Sent check changed RSVP status')
            client.restart()
        receipt = client.request('invitation.reply', **params)
        require(receipt['outcome'] == ('applied' if applied else 'unknown'), 'receipt state was not durable')
        require(client.request('cache.stats')['fixtureSends'] == int(applied), 'Sent checks resent the RSVP')
    return {'sent': int(applied), 'reconciled': applied, 'restarts': True, 'automaticResends': 0, 'tui': applied}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--capture-dir', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-rsvp-reconcile-') as tmp:
        results = []
        for applied in (False, True):
            directory = Path(tmp) / str(applied)
            directory.mkdir()
            results.append(scenario(args.binary.resolve(), directory, applied, args.capture_dir))
    receipt = {'build': read_build_info(args.binary.resolve()), 'cases': results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS RSVP receipt reconciliation: lost-before/lost-after, repeat and TUI Check Sent')


if __name__ == '__main__':
    main()
