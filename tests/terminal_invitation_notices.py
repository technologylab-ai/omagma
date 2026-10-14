#!/usr/bin/env python3
"""Scheduling notices: display offline, preserve identities, forbid accidental RSVP."""
import argparse
import base64
import copy
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_calendar import Invitations
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen


def run(binary, root, captures):
    fixture = Invitations(root)
    cases = [('request', False), ('publish', False), ('reply', False), ('cancel', True), ('request-cancelled', True)]
    source_file = fixture.root / 'accounts/personal.json'
    source = json.loads(source_file.read_text())
    template = source['messages'][0]
    source['messages'] = []
    for method, canceled in cases:
        message = copy.deepcopy(template)
        message['id'] = 'notice-' + method
        message['threadId'] = message['id']
        title = 'Notice ' + method
        message['snippet'] = title
        next(h for h in message['payload']['headers'] if h['name'] == 'Subject')['value'] = title
        part = next(p for p in message['payload']['parts'] if p['mimeType'] == 'text/calendar')
        raw = base64.urlsafe_b64decode(part['body']['data'] + '===').decode()
        raw = raw.replace('METHOD:REQUEST', 'METHOD:' + ('REQUEST' if method == 'request-cancelled' else method.upper()))
        if method == 'publish':
            raw = raw.replace('ORGANIZER:mailto:host@example.test\r\n', '').replace('ATTENDEE:mailto:' + ACCOUNTS[0] + '\r\n', '')
        if method == 'reply':
            raw = raw.replace('ATTENDEE:mailto:' + ACCOUNTS[0], 'ATTENDEE;PARTSTAT=ACCEPTED:mailto:guest@example.test')
        if canceled:
            raw = raw.replace('END:VEVENT', 'STATUS:CANCELLED\r\nEND:VEVENT')
        part['body'] = dict(size=len(raw.encode()), data=base64.urlsafe_b64encode(raw.encode()).decode().rstrip('='))
        source['messages'].append(message)
    source_file.write_text(json.dumps(source) + '\n')
    client_dir = root / 'client'
    with Client(binary, client_dir, extra=fixture.options()) as client:
        client.request('mail.list', label='INBOX')
        for method, canceled in cases:
            ident = 'notice-' + method
            client.request('mail.read', messageId=ident)
            before = client.request('cache.stats')['fixtureCalls']
            notice = client.request('invitation.inspect', messageId=ident, cacheOnly=True)
            require(notice['method'] == ('request' if method == 'request-cancelled' else method), 'display changed scheduling method')
            require(notice['cancelled'] == canceled, 'notice lost cancellation')
            require(notice['canReply'] == (method == 'request'), 'notice incorrectly authorizes RSVP')
            require(client.request('cache.stats')['fixtureCalls'] == before, 'cached inspection called the provider')
            if canceled:
                require(not notice['joinUrl'], 'cancellation offered a live Join link')
            if method != 'request':
                rejected = client.request('invitation.reply', messageId=ident, status='accepted', operationId='must-not-send-' + method, ok=False)
                require(bool(rejected), 'notice became an RSVP')
        require(client.request('cache.stats')['fixtureSends'] == 0, 'notice inspection submitted mail')
    terminal = MouseTerminal(binary, client_dir, extra=fixture.options(), screen_type=MouseScreen, columns=120, rows=35, environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "Europe/Vienna"})
    try:
        terminal.until(lambda: 'Up to date' in terminal.text())
        for method in ('cancel', 'reply', 'publish', 'request-cancelled'):
            terminal.send(('/subject:"Notice ' + method + '"\r').encode())
            terminal.until(lambda: 'Notice ' + method in terminal.text())
            terminal.gap(.3)
            terminal.send(b'I')
            terminal.until(lambda: 'Calendar notice' in terminal.text())
            require('a Accept' not in terminal.screen.lines()[-2], 'notice footer advertises RSVP')
            require('[Esc Close]' in terminal.text(), 'notice close control could be mistaken for cancelling the event')
            if method == 'reply':
                require("Attendee's RSVP · nothing to answer" in terminal.text(), 'received response does not explain why no answer is needed')
            if method == 'publish':
                require('Published event · no RSVP requested' in terminal.text(), 'published event asks for an RSVP')
                require('Attendee:' not in terminal.text() and 'Organizer:' not in terminal.text(), 'notice displays blank identities')
            terminal.send(b'atd')
            terminal.gap(.15)
            require('Calendar notice' in terminal.text(), 'notice response shortcut escaped the review')
            if captures:
                captures.mkdir(parents=True, exist_ok=True)
                (captures / ('notice-' + method + '.json')).write_text(json.dumps(screen_capture(terminal)) + '\n')
            terminal.send(b'\x1b')
            terminal.gap(.1)
            terminal.send(b'\x1b')
            terminal.gap(.1)
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    with Client(binary, client_dir, extra=fixture.options()) as client:
        require(client.request('cache.stats')['fixtureSends'] == 0, 'disabled notice shortcut sent mail')
    return {'methods': len(cases), 'offlineInspect': True, 'forbiddenRsvpSends': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--capture-dir', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='omagma-notices-') as tmp:
        result = run(binary, Path(tmp), args.capture_dir)
    receipt = {'build': read_build_info(binary), 'result': result}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS invitation notices: cached methods and TUI disabled RSVP')


if __name__ == '__main__':
    main()
