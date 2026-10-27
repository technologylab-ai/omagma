#!/usr/bin/env python3
"""Accept/Tentative Calendar continuation through the real TUI; synthetic only."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_calendar import Invitations, provider_state
from terminal_calendar_tui import start, search_mail, capture
from terminal_integration import Client, fixture_calendar_writes, require
from terminal_theme_picker import focused


def scenario(binary, directory, mode, captures):
    fixture = Invitations(directory)
    behavior = None if mode in ('accepted', 'tentative') else mode.removesuffix('-tentative')
    blocked = behavior in ('calendar-no-grant', 'calendar-offline')
    terminal = start(binary, directory / 'client', fixture, scenario=behavior, columns=116, rows=36,
                     no_color=blocked)
    expected_response = 'TENTATIVE' if mode == 'tentative' or mode.endswith('-tentative') else 'ACCEPTED'
    response_key = b't' if expected_response == 'TENTATIVE' else b'a'
    override_label = '[s ' + ('Tentative' if expected_response == 'TENTATIVE' else 'Accept') + ' without Calendar]'

    def counts(sends, writes):
        with Client(binary, directory / 'client', scenario=behavior, extra=fixture.options()) as client:
            require(client.request('cache.stats')['fixtureSends'] == sends,
                    'RSVP action sent mail without its explicit confirmation')
            require(fixture_calendar_writes(client) == writes,
                    'RSVP action changed Calendar unexpectedly')

    def wait_blocked():
        terminal.until(lambda: 'RSVP not sent' in terminal.text() and override_label in terminal.text()
                       and 'Working…' not in terminal.text())
        reason = ('Calendar write permission is missing' if behavior == 'calendar-no-grant'
                  else 'Calendar could not be reached')
        require(reason in terminal.text(), 'Calendar preflight blocker has no visible reason')
        require('Your confirmed RSVP:' not in terminal.text() and 'RSVP sent' not in terminal.text(),
                'blocked response was presented as sent')
        counts(0, 0)

    try:
        search_mail(terminal, 4)
        terminal.send(b'I')
        terminal.until(lambda: 'Meeting' in terminal.text() and '[a Accept]' in terminal.text())
        terminal.gap(.2)
        intent = 'adds supported events to your primary calendar'
        require((intent in terminal.text()) == (behavior != 'calendar-no-grant'),
                'RSVP review did not truthfully disclose automatic Calendar intent')
        capture(terminal, captures, mode + '-review')
        terminal.send(response_key)
        if blocked:
            wait_blocked()
            require('[C Check status]' not in terminal.text() and '[C Check Sent]' not in terminal.text(),
                    'blocked unsent RSVP exposed the recovery control as an override')
            terminal.send(b'C')
            terminal.gap(.2)
            wait_blocked()
            capture(terminal, captures, mode + '-blocked')
            # Enter initially stays on Cancel, even after a failed submission.
            require(focused(terminal, '[Esc Cancel]', no_color=True),
                    'blocked response moved keyboard focus to a sending action')
            terminal.send(b'\r')
            terminal.until(lambda: override_label not in terminal.text())
            counts(0, 0)
            terminal.send(b'I')
            terminal.until(lambda: 'Meeting' in terminal.text() and '[a Accept]' in terminal.text()
                           and 'RSVP not sent' not in terminal.text() and 'Working…' not in terminal.text())
            require('without Calendar]' not in terminal.text(), 'reopened card retained the blocked action')
            terminal.send(b's')
            terminal.gap(.15)
            counts(0, 0)
            terminal.send(response_key)
            wait_blocked()
            if behavior == 'calendar-offline':
                # Every control is available in this fixture, including its join link.
                terminal.send(b'\t' * 7)
                terminal.until(lambda: focused(terminal, override_label, no_color=True))
                counts(0, 0)
                capture(terminal, captures, mode + '-override-focused')
                terminal.send(b'\r')
            else:
                terminal.send(b's')
        terminal.until(lambda: 'RSVP sent' in terminal.text())
        if mode in ('accepted', 'tentative'):
            require('Calendar updated with your response' in terminal.text(), 'saved Calendar response hidden')
        elif mode == 'calendar-lost-response':
            require('Calendar not confirmed' in terminal.text(), 'unknown Calendar outcome claimed success')
        elif blocked:
            require('Calendar left unchanged as requested' in terminal.text(), 'explicit mail-only result hidden')
            require('Calendar not updated' not in terminal.text(), 'mail-only RSVP shown as failure')
            counts(1, 0)
        capture(terminal, captures, mode + '-result')
        terminal.send(b'I')
        terminal.until(lambda: 'Your confirmed RSVP: ' + expected_response in terminal.text()
                       and 'Working…' not in terminal.text())
        terminal.gap(.1)
        if blocked:
            require('RSVP only · Calendar left unchanged as requested' in terminal.text(),
                    'reopened card lost the explicit mail-only policy')
            require('[C Check status]' not in terminal.text() and 'without Calendar]' not in terminal.text(),
                    'mail-only response exposed a stale Calendar continuation or override')
            terminal.send(b'C')
            terminal.gap(.15)
            counts(1, 0)
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
    # Restore Calendar access after restart: an explicit mail-only choice must
    # still prevent inspection/reconciliation from creating an event.
    with Client(binary, directory / 'client', extra=fixture.options()) as client:
        require(client.request('cache.stats')['fixtureSends'] == 1, 'Calendar action resent the RSVP')
        inspected = client.request('invitation.inspect', messageId='calendar-mail-4', cacheOnly=True)
        require(inspected['confirmedResponse'] == expected_response, 'response lost after restart')
        sync = inspected.get('calendarSync') or {}
        if mode in ('accepted', 'tentative', 'calendar-lost-response'):
            require(sync.get('state') == 'applied', 'Calendar outcome not durable')
            state = provider_state(client)
            require(state['writes'] == 1, 'Calendar recovery duplicated its mutation')
        if blocked:
            require(sync.get('state') == 'skipped' and sync.get('errorCode') == 'RsvpOnlyRequested',
                    'mail-only Calendar policy was not durable')
            checked = client.request('invitation.inspect', messageId='calendar-mail-4', reconcile=True)
            require(checked['confirmedResponse'] == expected_response and checked['calendarSync'] == sync,
                    'reconciliation changed the saved mail-only response')
            client.restart()
            require(client.request('invitation.inspect', messageId='calendar-mail-4', cacheOnly=True)['calendarSync'] == sync,
                    'reconciliation did not preserve the mail-only policy across restart')
            require(fixture_calendar_writes(client) == 0, 'mail-only reconciliation wrote Calendar after access recovered')
        require(client.request('cache.stats')['fixtureSends'] == 1, 'inspection or reconciliation resent the RSVP')
        return {'case': mode, 'response': expected_response, 'calendarState': sync.get('state'),
                'mailSends': 1, 'calendarWrites': fixture_calendar_writes(client),
                'blockedBeforeOverride': blocked}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--capture-dir', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-invite-calendar-ui-') as temp:
        results = []
        for mode in ('accepted', 'tentative', 'calendar-no-grant', 'calendar-offline',
                     'calendar-offline-tentative', 'calendar-lost-response'):
            directory = Path(temp) / mode
            directory.mkdir()
            results.append(scenario(args.binary.resolve(), directory, mode, args.capture_dir))
    receipt = {'build': read_build_info(args.binary.resolve()), 'cases': results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS invitation Calendar TUI: blocked preflight, explicit mail-only override, durable recovery; no duplicate mail')


if __name__ == '__main__':
    main()
