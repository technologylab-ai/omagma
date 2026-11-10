#!/usr/bin/env python3
"""Accept/Tentative Calendar continuation through the real TUI; synthetic only."""
import argparse
import base64
from datetime import datetime, timezone
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
        require('Your response ·' not in terminal.text() and 'RSVP sent' not in terminal.text(),
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
        terminal.until(lambda: 'Your response · ' + expected_response.title() in terminal.text()
                       and 'Working…' not in terminal.text())
        terminal.gap(.1)
        if mode in ('accepted', 'tentative'):
            # The dimmed current answer is not resent by its key either.
            terminal.send(response_key)
            terminal.until(lambda: 'Already ' + expected_response.lower() + ' · choose another answer' in terminal.text())
            counts(1, 1)
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


def back_from_calendar(binary, directory):
    """I, A, q, d: Back from the Calendar review lands in the Mail reader, so
    a habitual d (Day inside Calendar) can never send a Decline."""
    fixture = Invitations(directory)
    terminal = start(binary, directory / 'client', fixture)
    try:
        search_mail(terminal, 4)
        terminal.send(b'I')
        terminal.until(lambda: 'Meeting' in terminal.text() and '[d Decline]' in terminal.text())
        terminal.send(b'A')
        terminal.until(lambda: 'Calendar · Review' in terminal.text() and 'Working…' not in terminal.text())
        terminal.send(b'q')
        terminal.until(lambda: 'Calendar review closed · nothing was added' in terminal.text())
        require('[d Decline]' not in terminal.text(), 'Back from Calendar reopened the RSVP drawer')
        terminal.send(b'd')
        terminal.gap(.6)
        require('Sending decline' not in terminal.text() and 'RSVP sent' not in terminal.text(),
                'a single d after Calendar Back sent an RSVP')
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    with Client(binary, directory / 'client', extra=fixture.options()) as client:
        require(client.request('cache.stats')['fixtureSends'] == 0, 'I, A, q, d sent mail')
        require(fixture_calendar_writes(client) == 0, 'I, A, q, d changed Calendar')
    return {'case': 'I-A-q-d', 'mailSends': 0, 'calendarWrites': 0}


EMBEDDED_ZONE = ('BEGIN:VTIMEZONE\r\nTZID:Custom Office\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\n'
                 'TZOFFSETFROM:+0300\r\nTZOFFSETTO:+0300\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT')
# variant: (source replacements, keys that choose a zone, expected UTC start, end)
ZONE_CASES = {
    # Outlook's Windows name: z uses the mapped suggestion, Europe/Berlin (CET).
    'windows': ([('DTSTART:20261025T090000Z', 'DTSTART;TZID=W. Europe Standard Time:20261125T090000'),
                 ('DTEND:20261025T100000Z', 'DTEND;TZID=W. Europe Standard Time:20261125T100000')],
                b'z', '2026-11-25T08:00:00Z', '2026-11-25T09:00:00Z', 'Europe/Berlin'),
    # An unknown TZID without rules: z offers the destination calendar's zone.
    'bogus': ([('DTSTART:20261025T090000Z', 'DTSTART;TZID=Bogus/Nowhere:20261125T090000'),
               ('DTEND:20261025T100000Z', 'DTEND;TZID=Bogus/Nowhere:20261125T100000')],
              b'z', '2026-11-25T09:00:00Z', '2026-11-25T10:00:00Z', 'UTC'),
    # Embedded +03:00 rules: Z types a zone that matches them.
    'embedded': ([('BEGIN:VEVENT', EMBEDDED_ZONE),
                  ('DTSTART:20261025T090000Z', 'DTSTART;TZID=Custom Office:20261125T090000'),
                  ('DTEND:20261025T100000Z', 'DTEND;TZID=Custom Office:20261125T100000')],
                 b'Z' + b'Etc/GMT-3' + b'\r', '2026-11-25T06:00:00Z', '2026-11-25T07:00:00Z', 'Etc/GMT-3'),
    # Mixed endpoints: only the unknown start takes the zone; New York stays.
    'mixed': ([('DTSTART:20261025T090000Z', 'DTSTART;TZID=Bogus/Nowhere:20261125T090000'),
               ('DTEND:20261025T100000Z', 'DTEND;TZID=America/New_York:20261125T100000')],
              b'z', '2026-11-25T09:00:00Z', '2026-11-25T15:00:00Z', 'UTC'),
    'mixed-floating': ([('DTSTART:20261025T090000Z', 'DTSTART:20261125T090000'),
                        ('DTEND:20261025T100000Z', 'DTEND;TZID=America/New_York:20261125T100000')],
                       b'z', '2026-11-25T09:00:00Z', '2026-11-25T15:00:00Z', 'UTC'),
    'floating': ([('DTSTART:20261025T090000Z', 'DTSTART:20261125T090000'),
                  ('DTEND:20261025T100000Z', 'DTEND:20261125T100000')],
                 b'z', '2026-11-25T09:00:00Z', '2026-11-25T10:00:00Z', 'UTC'),
}


def zoned_fixture(directory, replacements):
    class Zoned(Invitations):
        @staticmethod
        def message(account, sequence, cancel):
            value = Invitations.message(account, sequence, cancel)
            if sequence != 4:
                return value
            part = value['payload']['parts'][1]
            raw = base64.urlsafe_b64decode(part['body']['data'] + '==').decode()
            for old, new in replacements:
                require(old in raw, 'zone fixture replacement did not apply')
                raw = raw.replace(old, new)
            data = raw.encode()
            part['body'] = {'size': len(data), 'data': base64.urlsafe_b64encode(data).decode().rstrip('=')}
            return value
    return Zoned(directory)


def instant(value):
    point = value.get('dateTime') if isinstance(value, dict) else None
    require(point is not None, 'imported event has no timed start/end')
    return datetime.fromisoformat(point.replace('Z', '+00:00')).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def zone_choice(binary, directory, name):
    """Without z/Z nothing is assumed or written; after z/Z, Review and y the
    event is written at the instant the backend resolved for that zone."""
    replacements, choose, start_utc, end_utc, zone = ZONE_CASES[name]
    fixture = zoned_fixture(directory, replacements)
    terminal = start(binary, directory / 'client', fixture)

    def writes():
        with Client(binary, directory / 'client', extra=fixture.options()) as client:
            require(client.request('cache.stats')['fixtureSends'] == 0, 'zone review sent mail')
            return provider_state(client)

    try:
        search_mail(terminal, 4)
        terminal.send(b'A')
        terminal.until(lambda: 'Choose a time zone before adding' in terminal.text() and 'Working…' not in terminal.text())
        shown = terminal.text()
        require('as written' in shown and '→' not in shown and 'Assume ' not in shown,
                'zone review showed a converted time before the choice')
        require('[Z Type zone]' in shown, 'zone review has no Type zone button')
        # A bare Enter (and y) assume nothing and write nothing.
        terminal.send(b'\r')
        terminal.until(lambda: 'Nothing assumed' in terminal.text())
        terminal.send(b'y')
        terminal.gap(.4)
        require('Choose a time zone before adding' in terminal.text(), 'Enter or y left the zone choice')
        require(writes()['writes'] == 0, 'Calendar written without an explicit zone choice')
        terminal.send(choose)
        terminal.until(lambda: 'You chose to read its times' in terminal.text() and 'Working…' not in terminal.text())
        chosen = terminal.text()
        # The chosen zone is the user's; only a kept endpoint zone (New York
        # in the mixed cases) is the organizer's.
        require(f'as {zone}.' in chosen and f"organizer's zone: {zone}" not in chosen,
                'chosen zone was not disclosed as the user\'s choice')
        require(("organizer's zone: America/New_York" in chosen) == name.startswith('mixed'),
                'a valid end zone was overridden or mislabelled')
        require(writes()['writes'] == 0, 'choosing a zone wrote Calendar before review')
        terminal.send(b'\r')
        terminal.until(lambda: 'Saved review ready' in terminal.text())
        terminal.send(b'G')
        terminal.gap(.3)
        terminal.send(b'y')
        terminal.until(lambda: 'Calendar action applied' in terminal.text())
        terminal.send(b'q')
        terminal.until(lambda: 'Calendar' not in terminal.screen.lines()[0])
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    state = writes()
    require(state['writes'] == 1, 'confirmed zone review did not write exactly once')
    imported = [event['value'] for event in state['events'] if event['value'].get('iCalUID') == 'cli-planning@example.test']
    require(len(imported) == 1, 'imported invitation missing or duplicated')
    require(instant(imported[0]['start']) == start_utc and instant(imported[0]['end']) == end_utc,
            f'{name}: written at {imported[0]["start"]}–{imported[0]["end"]}, expected {start_utc}–{end_utc}')
    return {'case': 'zone-' + name, 'zone': zone, 'start': start_utc, 'end': end_utc, 'writes': 1, 'mailSends': 0}


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
        directory = Path(temp) / 'back-from-calendar'
        directory.mkdir()
        results.append(back_from_calendar(args.binary.resolve(), directory))
        for name in ZONE_CASES:
            directory = Path(temp) / ('zone-' + name)
            directory.mkdir()
            results.append(zone_choice(args.binary.resolve(), directory, name))
    receipt = {'build': read_build_info(args.binary.resolve()), 'cases': results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS invitation Calendar TUI: blocked preflight, explicit mail-only override, durable recovery, '
          'Back never re-enters the RSVP drawer, explicit zone choices write the resolved instant; no duplicate mail')


if __name__ == '__main__':
    main()
