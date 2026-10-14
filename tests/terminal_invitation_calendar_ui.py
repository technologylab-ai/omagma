#!/usr/bin/env python3
"""Accept/Tentative Calendar continuation through the real TUI; synthetic only."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_calendar import Invitations, provider_state
from terminal_calendar_tui import start, search_mail, capture
from terminal_integration import Client, require


def scenario(binary, directory, mode, captures):
    fixture = Invitations(directory)
    behavior = None if mode in ('accepted', 'tentative') else mode
    terminal = start(binary, directory / 'client', fixture, scenario=behavior, columns=116, rows=36)
    expected_response = 'TENTATIVE' if mode == 'tentative' else 'ACCEPTED'
    try:
        search_mail(terminal, 4)
        terminal.send(b'I')
        terminal.until(lambda: 'Meeting' in terminal.text() and '[a Accept]' in terminal.text())
        terminal.gap(.2)
        intent = 'adds supported events to your primary calendar'
        require((intent in terminal.text()) == (mode != 'calendar-no-grant'),
                'RSVP review did not truthfully disclose automatic Calendar intent')
        capture(terminal, captures, mode + '-review')
        terminal.send(b't' if mode == 'tentative' else b'a')
        terminal.until(lambda: 'RSVP sent' in terminal.text())
        if mode in ('accepted', 'tentative'):
            require('Calendar updated with your response' in terminal.text(), 'saved Calendar response hidden')
        elif mode == 'calendar-lost-response':
            require('Calendar not confirmed' in terminal.text(), 'unknown Calendar outcome claimed success')
        elif mode == 'calendar-offline':
            require('Calendar not updated' in terminal.text(), 'failed Calendar continuation hidden')
        elif mode == 'calendar-no-grant':
            require('Calendar not updated' not in terminal.text(), 'mail-only RSVP shown as failure')
        capture(terminal, captures, mode + '-result')
        terminal.send(b'I')
        terminal.until(lambda: 'Your confirmed RSVP: ' + expected_response in terminal.text()
                       and 'Working…' not in terminal.text())
        terminal.gap(.1)
        if mode == 'calendar-offline':
            require('[C Check status]' in terminal.text(), 'temporary Calendar failure has no Calendar-only retry')
        if mode == 'calendar-lost-response':
            require('[C Check status]' in terminal.text(), 'Calendar-only uncertainty has no recovery control')
            terminal.send(b'at')
            terminal.gap(.15)
            require('[C Check status]' in terminal.text(), 'Calendar uncertainty allowed another RSVP')
            terminal.send(b'C')
            terminal.until(lambda: 'Calendar updated with your response' in terminal.text())
            require('[C Check status]' not in terminal.text(), 'resolved Calendar still uncertain')
            capture(terminal, captures, mode + '-reconciled')
        terminal.send(b'\x1b')
        terminal.finish(expected_sends=1)
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    with Client(binary, directory / 'client', scenario=behavior, extra=fixture.options()) as client:
        require(client.request('cache.stats')['fixtureSends'] == 1, 'Calendar action resent the RSVP')
        inspected = client.request('invitation.inspect', messageId='calendar-mail-4', cacheOnly=True)
        require(inspected['confirmedResponse'] == expected_response, 'response lost after restart')
        sync = inspected.get('calendarSync') or {}
        if mode in ('accepted', 'tentative', 'calendar-lost-response'):
            require(sync.get('state') == 'applied', 'Calendar outcome not durable')
            state = provider_state(client)
            require(state['writes'] == 1, 'Calendar recovery duplicated its mutation')
        return {'case': mode, 'response': expected_response, 'calendarState': sync.get('state'), 'mailSends': 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--capture-dir', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-invite-calendar-ui-') as temp:
        results = []
        for mode in ('accepted', 'tentative', 'calendar-no-grant', 'calendar-offline', 'calendar-lost-response'):
            directory = Path(temp) / mode
            directory.mkdir()
            results.append(scenario(args.binary.resolve(), directory, mode, args.capture_dir))
    receipt = {'build': read_build_info(args.binary.resolve()), 'cases': results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS invitation Calendar TUI: Accept/Tentative, mail-only, offline, lost-response reconciliation; no duplicate mail')


if __name__ == '__main__':
    main()
