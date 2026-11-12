#!/usr/bin/env python3
"""Capture v0.2.19's five real stories in isolated fictional provider PTYs.

Run only through resource_guard.py with the coordinator's live HOST_TOKEN.
Every marked state is a completed native frame; no pixel, clock or provider
outcome is manufactured. --development labels exploratory evidence explicitly.
"""
from __future__ import annotations

import argparse
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'video/short0219'), str(ROOT / 'video/capture'),
               str(ROOT / 'tests'), str(ROOT / 'video/tools')]
from build_info import read_build_info
from capture_terminal import CaptureRecorder, self_test
from host_lock import identity, owner, start_ticks
from tape import save
from terminal_calendar import provider_state
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require

PERSONAL = ACCOUNTS[0]
ALEX, MAYA, JORDAN = 'alex@example.test', 'maya@example.org', 'jordan@example.org'
BILL_SENDER = 'billing@harbor-utilities.example'
KNOWN = (*ACCOUNTS, ALEX, MAYA, JORDAN, BILL_SENDER, 'calendar-owner@example.org',
         'payment-due@example.test', 'studio-sync@example.test')
BODY = 'Hi Maya,\nShall we try the new bakery on Saturday?\nI can book a table for ten.\nRobin'


def reserve():
    lock = owner()
    who = identity(lock) if lock else None
    require(lock and lock.get('token') == os.environ.get('HOST_TOKEN') and who
            and start_ticks(who[0]) == who[1], 'matching live coordinator HOST_TOKEN required')
    require(os.environ.get('OMAGMA_RESOURCE_GUARD') == 'short0219'
            and os.environ.get('OMAGMA_RESOURCE_GUARD_PID', '').isdigit(), 'run capture through short0219/resource_guard.py run')
    os.kill(int(os.environ['OMAGMA_RESOURCE_GUARD_PID']), 0)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


def message(ident, subject, body, sender, now, *, calendar=None):
    def part(kind, text, filename='', index='0'):
        data = text.encode()
        return {'partId': index, 'mimeType': kind, 'filename': filename,
                'headers': [{'name': 'Content-Type', 'value': kind + '; charset=utf-8'}],
                'body': {'size': len(data), 'data': base64.urlsafe_b64encode(data).decode().rstrip('=')}}
    payload = part('text/plain', body)
    if calendar:
        payload = {'partId': '', 'mimeType': 'multipart/mixed', 'filename': '', 'body': {'size': 0},
                   'parts': [payload, part('text/calendar', calendar, 'payment-due.ics', '1')]}
    payload['headers'] = [{'name': 'From', 'value': sender}, {'name': 'To', 'value': PERSONAL},
                          {'name': 'Subject', 'value': subject},
                          {'name': 'Message-ID', 'value': '<' + ident + '@example.test>'}]
    return {'id': ident, 'threadId': ident + '-thread', 'historyId': '500',
            'internalDate': str(int(now.timestamp() * 1000)), 'labelIds': ['INBOX'],
            'snippet': body, 'sizeEstimate': len(body.encode()) + 1000, 'payload': payload}


class Story:
    def __init__(self, directory, *, bill=False):
        self.directory = directory
        self.root = directory / 'provider'
        (self.root / 'accounts').mkdir(parents=True, mode=0o700)
        (self.root / 'contacts').mkdir(mode=0o700)
        self.now = datetime.now(timezone.utc)
        self.today = self.now.replace(hour=0, minute=0, second=0, microsecond=0)
        self.due = (self.today + timedelta(days=2)).date()
        self.preferences = directory / 'story-ui.json'
        sources = [{'account': a, 'calendarId': c, 'visible': a == c == PERSONAL,
                    'color': 'blue' if a == PERSONAL else 'orange'}
                   for a in ACCOUNTS for c in (a, 'fixture-shared-team', 'fixture-readonly')]
        write_json(self.preferences, {'schema': 1, 'theme': 'omagma', 'calendarLook': 'orange_blue',
                   'readerLayout': 'right', 'lastAccount': PERSONAL,
                   'calendar': {'scope': 'all_accounts', 'sources': sources}})
        self.config = directory / 'story-config.json'
        config = json.loads((ROOT / 'tests/fixtures/all-accounts.json').read_text())
        for account in config['accounts']:
            account.update(senderName='Robin Example', signature='')
        write_json(self.config, config)
        inbox = [('lunch', 'Lunch on Saturday?', 'Maya Example <' + MAYA + '>', 'The new bakery looks lovely. Shall we go?'),
                 ('alex-plan', 'Planning lunch', 'Alex Example <' + ALEX + '>', 'I can bring the planning notes.'),
                 ('studio', 'Studio notes', 'Jordan Example <' + JORDAN + '>', 'A few ideas for our next conversation.'),
                 ('weekend', 'Weekend reading', 'Maya Example <' + MAYA + '>', 'Two short stories for the weekend.'),
                 ('books', 'Your book is ready', 'Library <books@example.org>', 'Your reserved book is ready to collect.'),
                 ('walk', 'Sunday walk', 'Jordan Example <' + JORDAN + '>', 'Meet at the park after lunch?')]
        for account in ACCOUNTS:
            messages = [message(ident, title, body, sender, self.now - timedelta(minutes=i * 20))
                        for i, (ident, title, sender, body) in enumerate(inbox)]
            if bill:
                raw = ('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Example//Bill reminder//EN\r\nMETHOD:PUBLISH\r\n'
                       'BEGIN:VEVENT\r\nUID:payment-due@example.test\r\nDTSTAMP:' + self.now.strftime('%Y%m%dT%H%M%SZ') + '\r\n'
                       'DTSTART;VALUE=DATE:' + self.due.strftime('%Y%m%d') + '\r\n'
                       'DTEND;VALUE=DATE:' + (self.due + timedelta(days=1)).strftime('%Y%m%d') + '\r\n'
                       'SUMMARY:Pay Harbor Utilities bill\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n'
                       'DESCRIPTION:Bill reminder\r\nTRIGGER:-PT15H\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n')
                messages.insert(0, message('utility-bill', 'Your November bill',
                    'EUR 48.20 is due on ' + self.due.strftime('%d %B') + '. A calendar reminder is attached.',
                    'Harbor Utilities <' + BILL_SENDER + '>', self.now + timedelta(minutes=1), calendar=raw))
                self.calendar_source = raw
            write_json(self.root / 'accounts' / (account.split('@')[0] + '.json'), {
                'account': account, 'generation': 500, 'sync': {'historyId': '500', 'history': []},
                'identities': [{'address': account, 'name': 'Robin Example', 'signature': '', 'isDefault': True}],
                'messages': messages})
            # Alex comes from recent mail, without a contacts/provider lookup while typing.
            write_json(self.root / 'contacts' / (account.split('@')[0] + '.json'), {'account': account, 'connections': []})

    def options(self):
        return ('--fixture-root', str(self.root), '--prefetch-bodies', '0', '--config', str(self.config))

    def seed(self, binary, events):
        with Client(binary, self.directory, extra=self.options()) as client:
            for account in ACCOUNTS:
                client.request('mail.refresh', account, label='INBOX', limit=30, prefetchLimit=6)
                client.request('accounts.identities', account)
                client.request('calendar.list', account)
                client.request('contacts.list', account)
        for path in (self.directory / 'cache').rglob('calendar-provider-fixture.json'):
            state = json.loads(path.read_text())
            require(state['writes'] == 0, 'seeding unexpectedly wrote Calendar')
            state['events'] = [{'calendar_id': PERSONAL, 'value': value} for value in events] if state['account'] == PERSONAL else []
            write_json(path, state)


def event(story, ident, title, first, minutes=60, *, all_day=False, invitation=False):
    value = {'id': ident, 'iCalUID': ident + '@example.test', 'etag': '"film019-' + ident + '"',
             'status': 'confirmed', 'summary': title,
             'organizer': {'email': JORDAN if invitation else PERSONAL, 'displayName': 'Jordan Example' if invitation else 'Robin Example'},
             'start': {'date': first.date().isoformat()} if all_day else {'dateTime': first.isoformat().replace('+00:00', 'Z')},
             'end': {'date': (first + timedelta(days=1)).date().isoformat()} if all_day else
                    {'dateTime': (first + timedelta(minutes=minutes)).isoformat().replace('+00:00', 'Z')}}
    if invitation:
        value['attendees'] = [{'email': PERSONAL, 'self': True, 'displayName': 'Robin Example', 'responseStatus': 'needsAction'}]
    return value


def start(binary, story, name, columns, rows):
    rec = CaptureRecorder(binary, story.directory, name, extra=(*story.options(), '--account', PERSONAL,
                          '--ui-file', str(story.preferences)), columns=columns, rows=rows)
    rec.wait(lambda: 'Lunch on Saturday?' in rec.text() and ('Up to date' in rec.text() or 'Ready' in rec.text()))
    return rec


def calendar(rec, view='2'):
    rec.press('C', rec.name + '.calendar.open', show=False)
    rec.wait(lambda: 'Calendar · Agenda' in rec.text())
    rec.press('t' + view, rec.name + '.calendar.view', show=False)
    rec.wait(lambda: 'Calendar · ' + {'2': 'Day', '3': 'Week'}[view] in rec.text() and 'Loading' not in rec.text())


def mark(rec, manifest, out, key, needle=None):
    rec.wait(lambda: needle is None or needle in rec.text())
    require(not rec.screen.synchronized and not rec.screen.frame_open, 'incomplete native frame')
    rec.mark(key)
    manifest['assets'][key] = {'tape': rec.name + '.json', 'mark': key, 'frame': rec.marks[-1]['frame']}
    write_json(out / (key + '-screen.json'), screen_capture(rec))


def preserve(rec, manifest, out):
    try:
        write_json(out / (rec.name + '-final-screen.json'), screen_capture(rec))
        save(out / (rec.name + '.json'), rec.tape(manifest['buildInfo']), known=KNOWN)
    finally:
        rec.close()


def counts(binary, story):
    with Client(binary, story.directory, extra=story.options()) as client:
        stats = {account: client.request('cache.stats', account) for account in ACCOUNTS}
        states = {account: provider_state(client, account) for account in ACCOUNTS}
    return {'fixtureCalls': sum(s['fixtureCalls'] for s in stats.values()),
            'fixtureSends': sum(s['fixtureSends'] for s in stats.values()),
            'calendarWrites': sum(s['writes'] for s in states.values()),
            'mailboxProviderWrites': sum(s['fixtureProviderEntries'] for s in stats.values()), 'states': states}


def zero(value):
    require(value['fixtureSends'] == value['calendarWrites'] == value['mailboxProviderWrites'] == 0, 'read-only story wrote Calendar or sent mail')


def focus(rec, label):
    for index in range(40):
        point = rec.screen.locate(label + ':')
        if point and '▏' in rec.screen.lines()[point['row']]:
            return
        before = rec.screen.completed_frames
        rec.press(b'\t', rec.name + '.focus.' + label + '.' + str(index), show=False)
        rec.wait(lambda: rec.screen.completed_frames > before)
    raise AssertionError('unreachable field ' + label)


def fill(rec, label, value):
    focus(rec, label)
    rec.press(b'\x05' + b'\x7f' * 128 + b'\x1b[200~' + value.encode() + b'\x1b[201~',
              rec.name + '.fill.' + label, show=False)
    rec.wait(lambda: value in rec.text())


def now_proof(rec, earlier, later):
    # v0.2.19 paints native horizontal glyphs in free time, retaining red
    # underlines only when a block occupies that cell. Accept actual pixels,
    # never synthesize v0.2.18's spelling or all-space underline style.
    candidates = []
    for y, line in enumerate(rec.screen.lines()):
        if not re.match(r'^\d{2}:\d{2}[│┤]', line):
            continue
        columns = [x for x, (glyph, style) in enumerate(zip(rec.screen.cells[y], rec.screen.styles[y]))
                   if glyph == '─' and style[0] and style[0][0] == 'rgb'
                   and style[0][1] > 140 and style[0][1] > style[0][2] * 1.3 and style[0][1] > style[0][3] * 1.1]
        if len(columns) >= 6:
            candidates.append((y, columns))
    require(len(candidates) == 1, 'actual OS current-time line not uniquely visible; capture later')
    row, columns = candidates[0]
    label = ''.join(rec.screen.cells[row][:5])
    now = datetime.now(timezone.utc)
    captured_minute = int(label[:2]) * 60 + int(label[3:])
    require(abs(captured_minute - (now.hour * 60 + now.minute)) <= 1, 'native current-time label differs from OS clock')
    first, last = rec.screen.locate(earlier), rec.screen.locate(later)
    require(first and last and first['row'] <= row - 1 and last['row'] >= row + 1, 'earlier/later blocks do not bracket now')
    return {'captureUtc': now.isoformat(), 'captureLocal': datetime.now().astimezone().isoformat(),
            'clock': 'Actual operating-system real time; no clock override', 'calendarClockZone': 'UTC', 'row': row, 'nativeClockLabel': label,
            'nativeLineColumns': columns, 'nativeLineGlyphs': [rec.screen.cells[row][x] for x in columns],
            'nativeLineColors': [rec.screen.styles[row][x][0] for x in columns],
            'earlierEventCell': first, 'laterEventCell': last}


def grid(binary, directory, out, manifest):
    story = Story(directory)
    hour = story.now.replace(minute=0, second=0, microsecond=0)
    require(8 <= hour.hour <= 18, 'real UTC clock outside supported capture hours; wait, never fake clock')
    events = [event(story, 'recycling', 'Recycling day', story.today, all_day=True),
              event(story, 'standup', 'Standup', hour - timedelta(hours=2), 45),
              event(story, 'design', 'Design crit', hour + timedelta(hours=1), 90),
              event(story, 'vendor', 'Vendor call', hour + timedelta(hours=1), 60)]
    monday = story.today - timedelta(days=story.today.weekday())
    for i, title in enumerate(('Gym', 'Lunch w/ Sam', 'Dentist', '1:1 Priya')):
        day = monday + timedelta(days=(story.today.weekday() + i + 1) % 7, hours=hour.hour - 1)
        events.append(event(story, 'neighbor-' + str(i), title, day, 45))
    events.append(event(story, 'neighbor-allday', 'Book return', story.today + timedelta(days=1), all_day=True))
    story.seed(binary, events)
    rec = start(binary, story, 'calendar', 104, 30)
    try:
        calendar(rec, '3')
        rec.wait(lambda: 'Standup' in rec.text() and 'Design' in rec.text())
        week_setup = []
        for index in range(8):
            later = rec.screen.locate('Design')
            header_row = next(y for y, row in enumerate(rec.screen.cells) if row[5] == '│'
                              and any(day in ''.join(row) for day in ('Mon ', 'Tue ', 'Wed ', 'Thu ', 'Fri ', 'Sat ', 'Sun ')))
            if later and later['row'] + 2 <= header_row + 19:
                break
            rec.press(b'\x05', 'calendar.setup.week-time-axis.' + str(index), show=False)
            week_setup.append('Ctrl+E')
            rec.gap(.06)
        else:
            raise AssertionError('real Week axis setup could not fit today within19 rows')
        week_now = now_proof(rec, 'Standup', 'Des')
        mark(rec, manifest, out, 'calendar.week')
        rec.press('2', 'calendar.day.press')
        rec.wait(lambda: 'Calendar · Day' in rec.text() and 'Design crit' in rec.text() and 'Vendor call' in rec.text())
        # Day is the genuine immediate result of the film's visible 2 key.
        # Unlike the Week pre-roll, no time-axis key may be inserted here.
        day_setup = []
        later = rec.screen.locate('Design crit')
        x, y = later['column'], later['row']
        background = rec.screen.styles[y][x][1]
        last = y
        while last + 1 < rec.rows and rec.screen.styles[last + 1][x][1] == background:
            last += 1
        require(last < 25, 'immediate Day result clips the complete block in its authored23-row camera')
        day_now = now_proof(rec, 'Standup', 'Design crit')
        first_lane, second_lane = rec.screen.locate('Design crit'), rec.screen.locate('Vendor call')
        require(first_lane['row'] == second_lane['row'], 'Day overlap titles are not on the same native time row')
        lane_ranges = [[first_lane['column'] - 1, second_lane['column'] - 1], [second_lane['column'] - 1, rec.columns - 1]]
        require(all(last - first >= 8 for first, last in lane_ranges)
                and all(rec.screen.cells[first_lane['row']][first] == '▌' for first, _ in lane_ranges),
                'native Day overlap does not have two distinct readable lane ranges')
        day_now['laneColumnRanges'] = lane_ranges
        day_now['laneTitleRow'] = first_lane['row']
        day_now['lastColoredBlockRow'] = last
        day_now['cameraEndExclusiveRow'] = 25
        require(last < 25, 'Day crop clips the complete later block')
        mark(rec, manifest, out, 'calendar.day')
        before = counts(binary, story)
        looks = [json.loads(story.preferences.read_text())['calendarLook']]
        rec.press(b'\x14', 'calendar.classic.press')
        rec.wait(lambda: 'Calendar look: Classic' in rec.text())
        looks.append(json.loads(story.preferences.read_text())['calendarLook'])
        classic_counts = counts(binary, story)
        mark(rec, manifest, out, 'calendar.day-classic')
        rec.press(b'\x14', 'calendar.orange-blue.press')
        rec.wait(lambda: 'Calendar look: Orange & Blue' in rec.text())
        looks.append(json.loads(story.preferences.read_text())['calendarLook'])
        after = counts(binary, story)
        mark(rec, manifest, out, 'calendar.day-back')
        require(before['fixtureCalls'] == classic_counts['fixtureCalls'] == after['fixtureCalls'], 'look toggle queried provider')
        require(looks == ['orange_blue', 'classic_pastel', 'orange_blue'], 'look preferences did not round-trip')
        zero(after)
        manifest['proofs']['calendar'] = {'weekNow': week_now, 'dayNow': day_now, 'seedUtc': story.now.isoformat(),
            'events': events, 'looks': looks, 'viewportSetupKeys': {'week': week_setup, 'day': day_setup}, 'providerCalls': [before['fixtureCalls'], classic_counts['fixtureCalls'], after['fixtureCalls']],
            'calendarWrites': 0, 'fixtureSends': 0}
        manifest['cleanup']['calendar'] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest, out)


def guests(binary, directory, out, manifest):
    story = Story(directory)
    story.seed(binary, [])
    rec = start(binary, story, 'guests', 96, 26)
    try:
        calendar(rec)
        rec.press('n', 'guest.new-event', show=False)
        rec.wait(lambda: 'New event' in rec.text() and '[Ctrl+S Review]' in rec.text() and '[Working…]' not in rec.text())
        fill(rec, 'Title', 'Planning lunch')
        focus(rec, 'Guests')
        rec.wait(lambda: 'Browse all' in rec.text())
        mark(rec, manifest, out, 'guest.empty')
        before = counts(binary, story)
        rec.press('a', 'guest.type-a')
        rec.gap(.08)
        require('Suggestions ·' not in rec.text(), 'suggestions appeared after one character')
        mark(rec, manifest, out, 'guest.typed')
        rec.press('l', 'guest.type-l')
        rec.wait(lambda: ALEX in rec.text() and 'Suggestions ·' in rec.text())
        require('Enter Next field' in rec.text(), 'unselected popup does not advertise ordinary Next field')
        mark(rec, manifest, out, 'guest.suggest')
        candidate = rec.screen.locate(ALEX)
        unselected_style = copy.deepcopy(rec.screen.styles[candidate['row']][candidate['column']])
        rec.press(b'\x1b[B', 'guest.choose-down')
        rec.wait(lambda: rec.screen.styles[candidate['row']][candidate['column']] != unselected_style)
        require('Enter/Tab Add' in rec.text(), 'chosen popup does not advertise explicit Add')
        mark(rec, manifest, out, 'guest.selected')
        rec.press(b'\r', 'guest.add-enter')
        rec.wait(lambda: 'Suggestions ·' not in rec.text() and ALEX in rec.text())
        field = next(line for line in rec.screen.lines() if 'Guests:' in line)
        require(ALEX in field and 'al,' not in field and ' al ' not in field, 'guest insertion retained unfinished token')
        mark(rec, manifest, out, 'guest.added')
        after = counts(binary, story)
        zero(after)
        require(before['fixtureCalls'] == after['fixtureCalls'], 'typing queried a provider')
        manifest['proofs']['guests'] = {'providerCallsBefore': before['fixtureCalls'], 'providerCallsAfter': after['fixtureCalls'],
            'selectedAddress': ALEX, 'field': field, 'unselectedStyle': unselected_style,
            'nothingSelectedBeforeDown': True, 'calendarWrites': 0, 'fixtureSends': 0}
        rec.press(b'\x1b', 'guest.leave-unsaved', show=False)
        rec.wait(lambda: 'Discard your unsaved event?' in rec.text())
        rec.press(b'\x04', 'guest.discard-unsaved', show=False)
        rec.wait(lambda: 'Title:' not in rec.text() and 'Discard your unsaved event?' not in rec.text())
        manifest['cleanup']['guests'] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest, out)


def rsvp(binary, directory, out, manifest):
    story = Story(directory)
    hour = story.now.replace(minute=0, second=0, microsecond=0)
    events = [event(story, 'studio-sync', 'Studio sync', hour + timedelta(hours=2), 60, invitation=True),
              event(story, 'focus', 'Focus time', hour - timedelta(hours=2), 45),
              event(story, 'walk', 'Evening walk', hour + timedelta(hours=3), 45)]
    story.seed(binary, events)
    rec = start(binary, story, 'rsvp', 96, 22)
    try:
        calendar(rec)
        # Keyboard selection, without a filter that would hide the neighbors.
        for i in range(12):
            if any('▸' in line and 'Studio sync' in line for line in rec.screen.lines()):
                break
            rec.press('j', 'rsvp.select.' + str(i), show=False)
            rec.gap(.08)
        require(any('▸' in line and 'Studio sync' in line for line in rec.screen.lines()), 'invitation not selected')
        mark(rec, manifest, out, 'rsvp.before')
        rec.press('r', 'rsvp.review.press')
        rec.wait(lambda: 'Your answer now · Not answered' in rec.text() and 'Checking' not in rec.text())
        mark(rec, manifest, out, 'rsvp.review')
        zero(counts(binary, story))
        rec.press('a', 'rsvp.accept.press')
        rec.wait(lambda: '[y Accept' in rec.text() and '(•) Accept' in rec.text())
        mark(rec, manifest, out, 'rsvp.accept')
        zero(counts(binary, story))
        hold = time.monotonic()
        rec.gap(.75)
        rec.mark('rsvp.confirm-hold', visibleReviewSeconds=time.monotonic() - hold)
        rec.press('y', 'rsvp.confirm.press')
        rec.wait(lambda: 'Accepted · Studio sync' in rec.text() and 'Your answer now' not in rec.text())
        rec.wait(lambda: 'Loading' not in rec.text())
        mark(rec, manifest, out, 'rsvp.done')
        after = counts(binary, story)
        state = after['states'][PERSONAL]
        require(after['calendarWrites'] == 1 and after['fixtureSends'] == 0, 'RSVP did not patch exactly once')
        requests = state.get('requests', [])
        require(len(requests) == 1 and requests[0]['method'] == 'PATCH'
                and requests[0]['eventId'] == 'studio-sync' and requests[0]['ifMatch'] == events[0]['etag'], 'RSVP lacks exact version-checked patch')
        saved = next(e['value'] for e in state['events'] if e['value']['id'] == 'studio-sync')
        require(saved['attendees'][0]['email'] == PERSONAL and saved['attendees'][0]['responseStatus'] == 'accepted', 'RSVP changed wrong attendee')
        manifest['proofs']['rsvp'] = {'beforeConfirmationWrites': 0, 'calendarWrites': 1, 'fixtureSends': 0,
                                    'request': requests[0], 'event': saved, 'reviewHoldSeconds': time.monotonic() - hold}
        manifest['cleanup']['rsvp'] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest, out)


def ics(binary, directory, out, manifest):
    story = Story(directory, bill=True)
    due = datetime.combine(story.due, datetime.min.time(), timezone.utc)
    events = [event(story, 'market', 'Market visit', due + timedelta(hours=10), 45),
              event(story, 'lunch', 'Lunch with Maya', due + timedelta(hours=13), 60)]
    story.seed(binary, events)
    rec = start(binary, story, 'ics', 96, 28)
    try:
        rec.wait(lambda: 'Your November bill' in rec.text())
        rec.press(b'\r', 'ics.open-mail', show=False)
        rec.wait(lambda: 'payment-due.ics' in rec.text())
        rec.press('z', 'ics.expand-reader', show=False)
        rec.wait(lambda: BILL_SENDER in rec.text() and 'payment-due.ics' in rec.text() and 'Pay Harbor Utilities bill' in rec.text())
        mark(rec, manifest, out, 'ics.mail')
        rec.press('A', 'ics.review.press')
        rec.wait(lambda: '[y Add' in rec.text() and 'Pay Harbor Utilities bill' in rec.text()
                 and 'Reminder' in rec.text() and 'Checking Google Calendar' not in rec.text() and 'Working…' not in rec.text())
        mark(rec, manifest, out, 'ics.review')
        zero(counts(binary, story))
        rec.press('y', 'ics.confirm.press')
        rec.wait(lambda: 'Added to your primary calendar.' in rec.text())
        mark(rec, manifest, out, 'ics.saved')
        after = counts(binary, story)
        require(after['calendarWrites'] == 1 and after['fixtureSends'] == 0, 'ICS did not insert exactly once')
        inserted = [e['value'] for e in after['states'][PERSONAL]['events'] if e['value']['summary'] == 'Pay Harbor Utilities bill']
        require(len(inserted) == 1, 'ICS insertion identity missing or duplicated')
        added = inserted[0]
        require(added['start'] == {'date': story.due.isoformat()} and added['end'] == {'date': (story.due + timedelta(days=1)).isoformat()}
                and not added.get('attendees') and added.get('reminders') == {'useDefault': False, 'overrides': [{'method': 'popup', 'minutes': 900}]},
                'ICS all-day date, attendees or popup reminder changed')
        rec.press('q', 'ics.close-result', show=False)
        rec.wait(lambda: 'Added to your primary calendar.' not in rec.text())
        if 'Calendar ·' not in rec.screen.lines()[0]:
            rec.press('C', 'ics.open-calendar', show=False)
            rec.wait(lambda: 'Calendar ·' in rec.text())
        rec.press('2', 'ics.day-view', show=False)
        rec.wait(lambda: 'Calendar · Day' in rec.text())
        for index in range(2):
            rec.press('l', 'ics.due-date.' + str(index), show=False)
            rec.gap(.12)
        rec.wait(lambda: all(title in rec.text() for title in ('Pay Harbor Utilities bill', 'Market visit', 'Lunch with Maya')))
        mark(rec, manifest, out, 'ics.calendar')
        manifest['proofs']['ics'] = {'calendarWrites': 1, 'fixtureSends': 0, 'calendarId': PERSONAL,
            'source': story.calendar_source, 'sourceSha256': hashlib.sha256(story.calendar_source.encode()).hexdigest(),
            'event': added, 'requests': after['states'][PERSONAL].get('requests', []), 'dueDate': story.due.isoformat(),
            'populatedTimedEvents': [e['summary'] for e in events]}
        manifest['cleanup']['ics'] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest, out)


def draft_value(binary, story):
    with Client(binary, story.directory, extra=story.options()) as client:
        rows = client.request('draft.list', PERSONAL)['drafts']
        return [client.request('draft.read', PERSONAL, draftId=row['id']) for row in rows]


def draft(binary, directory, out, manifest):
    story = Story(directory)
    story.seed(binary, [])
    rec = start(binary, story, 'draft', 96, 24)
    try:
        rec.press('c', 'draft.compose', show=False)
        rec.wait(lambda: 'Subject:' in rec.text() and 'Body:' in rec.text())
        rec.press('i' + MAYA + '\t\t\tSaturday plans\t', 'draft.headers', show=False)
        rec.mark('draft.type-body', typed=BODY)
        for index, line in enumerate(BODY.splitlines()):
            if index:
                rec.press(b'\r', 'draft.body-enter.' + str(index), show=False)
            rec.type(line, 'draft.body-line.' + str(index), delay=.035)
        rec.mark('draft.type-body:done')
        rec.wait(lambda: 'I can book a table for ten.' in rec.text() and 'Robin' in rec.text())
        deadline = time.monotonic() + 8
        while True:
            before = draft_value(binary, story)
            if len(before) == 1 and (before[0].get('recoveryFields') or [None] * 4 + [before[0]['bodyText']])[4] == BODY:
                break
            require(time.monotonic() < deadline, 'typed source did not persist exactly')
            rec.gap(.08)
        # An ordinary local review validates provisional autosave fields. Its
        # exact native MIME result is observed, then Escape returns without a
        # send. Setup precedes the film's first state; the visible discard /
        # restore chain below contains no hidden repair or post-restore key.
        rec.press(b'\x13', 'draft.setup.validate-local-review', show=False)
        rec.wait(lambda: 'Sending account:' in rec.text() and 'MIME:' in rec.text() and '[y Send]' in rec.text())
        exact_mime = re.search(r'MIME: (\d+) / (\d+) bytes · exact', rec.text())
        require(exact_mime is not None, 'ordinary setup review did not validate exact local MIME')
        reviewed_bytes, reviewed_limit = map(int, exact_mime.groups())
        rec.mark('draft.setup.validated-local-review', exactMimeBytes=reviewed_bytes, maxMimeBytes=reviewed_limit)
        rec.press(b'\x1b', 'draft.setup.return-without-send', show=False)
        rec.wait(lambda: 'Compose' in rec.text() and 'Sending account:' not in rec.text())
        rec.press('i', 'draft.setup.insert-without-editing', show=False)
        rec.wait(lambda: 'Body: INSERT' in rec.text() and 'MIME:' in rec.text() and 'UnfinishedDraft' not in rec.text())
        before = draft_value(binary, story)
        require(len(before) == 1 and before[0].get('recoveryFields') is None and before[0]['bodyText'] == BODY,
                'pre-reviewed setup changed the typed body or kept provisional fields')
        typing_cells = copy.deepcopy(rec.screen.cells)
        mark(rec, manifest, out, 'draft.typing')
        rec.press(b'\x18', 'draft.review.press')
        rec.wait(lambda: 'Discard local draft' in rec.text() and 'Ctrl+X again discards' in rec.text())
        mark(rec, manifest, out, 'draft.review')
        rec.gap(1.2)
        rec.mark('draft.confirm-hold', visibleReviewSeconds=1.2)
        rec.press(b'\x18', 'draft.discard.press')
        rec.wait(lambda: 'Draft discarded · Ctrl+Z Undo' in rec.text() and 'Subject:' not in rec.text())
        mark(rec, manifest, out, 'draft.discarded')
        discarded = draft_value(binary, story)
        require(discarded == [], 'discarded draft remained live')
        rec.press(b'\x1a', 'draft.restore.press')
        rec.wait(lambda: 'Subject: Saturday plans' in rec.text() and 'I can book a table for ten.' in rec.text())
        rec.wait(lambda: 'MIME:' in rec.text() and 'UnfinishedDraft' not in rec.text())
        mark(rec, manifest, out, 'draft.restored')
        restored = draft_value(binary, story)
        require(restored == before, 'Ctrl+Z did not restore exact retained draft data')
        body_rows = [y for y, row in enumerate(typing_cells) if any(line in ''.join(row[:rec.columns * 3 // 5]) for line in BODY.splitlines())]
        require(len(body_rows) == 4 and all(typing_cells[y] == rec.screen.cells[y] for y in body_rows), 'restored body cells differ')
        after = counts(binary, story)
        zero(after)
        gmail_ledgers = list((story.directory / 'cache').rglob('fixture-gmail-drafts.json'))
        require(not gmail_ledgers, 'local discard contacted Gmail draft provider')
        manifest['proofs']['draft'] = {'fixtureSends': 0, 'calendarWrites': 0, 'gmailDraftDeletes': 0, 'gmailProviderLedgerCount': len(gmail_ledgers), 'mailboxProviderWrites': after['mailboxProviderWrites'],
            'draftId': before[0]['id'], 'sourceBody': BODY, 'bodyRows': body_rows,
            'cellForCellBodyEqual': True, 'lifecycle': [{'state': 'live', 'count': len(before)},
               {'state': 'discarded-kept', 'count': len(discarded)}, {'state': 'restored', 'count': len(restored)}],
            'restoredDataEqualsOriginal': True, 'preReviewedSetup': {
                'keys': ['Ctrl+S', 'Esc', 'i'], 'beforeInitialState': True,
                'exactMimeBytes': reviewed_bytes, 'maxMimeBytes': reviewed_limit, 'sendConfirmed': False,
                'recoveryFieldsAfterSetup': False, 'postRestoreKeys': []}}
        manifest['cleanup']['draft'] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest, out)


TAKES = {'grid': grid, 'guests': guests, 'rsvp': rsvp, 'ics': ics, 'draft': draft}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--takes', default=','.join(TAKES))
    parser.add_argument('--development', action='store_true', help='exploratory capture; never publish as released evidence')
    parser.add_argument('--candidate-proof', type=Path, help='immutable successful frozen native artifact receipt; publication remains separately required')
    args = parser.parse_args()
    reserve()
    self_test()
    binary = args.binary.resolve()
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == args.expected_sha256, 'capture executable changed')
    info = read_build_info(binary, 'safe')
    require(args.development or info['appVersion'] == '0.2.19', 'production capture requires v0.2.19')
    require(not (args.development and args.candidate_proof), 'candidate and development statuses are distinct')
    candidate_raw = None
    candidate = None
    if args.candidate_proof:
        candidate_raw = args.candidate_proof.read_bytes()
        require(len(candidate_raw) <= 256 * 1024, 'candidate receipt exceeds bound')
        candidate = json.loads(candidate_raw)
        require(candidate.get('schema') == 'omagma.video.frozen-candidate.v1', 'wrong frozen candidate proof schema')
        require(candidate.get('binarySha256') == args.expected_sha256, 'frozen native artifact SHA differs from capture executable')
        require(str(candidate.get('run', '')).isdigit() and str(candidate.get('artifact', '')).isdigit()
                and re.fullmatch(r'[0-9a-f]{40}', candidate.get('head', ''))
                and candidate.get('jobConclusion') == 'success', 'candidate proof needs exact run/head/artifact and successful native job')
        require(info == {'zigVersion': '0.17.0', 'buildMode': 'safe', 'appVersion': '0.2.19'}, 'candidate backend identity differs from required native release')
    selected = args.takes.split(',')
    require(all(name in TAKES for name in selected) and len(set(selected)) == len(selected), 'unknown or duplicate take')
    out = args.out.resolve()
    require(not out.exists(), 'preserve previous capture attempts: output already exists')
    out.mkdir(parents=True)
    status = 'frozen-release-candidate' if candidate else 'development-only' if args.development else 'published-v0.2.19'
    manifest = {'schema': 'omagma.video.capture.v1', 'binarySha256': args.expected_sha256,
        'buildInfo': info, 'sourceStatus': status, 'sourceStatusAtCapture': status,
        'assets': {}, 'proofs': {}, 'cleanup': {}, 'synthetic': True, 'liveProviderWrites': 0,
        'userClipboardRead': False, 'storyDateUtc': datetime.now(timezone.utc).date().isoformat()}
    if candidate:
        (out / 'frozen-candidate-proof.json').write_bytes(candidate_raw)
        (out / 'frozen-candidate-proof.json').chmod(0o600)
        manifest['candidateProof'] = {'file': 'frozen-candidate-proof.json',
            'sha256': hashlib.sha256(candidate_raw).hexdigest(), 'run': candidate['run'], 'head': candidate['head'],
            'artifact': candidate['artifact'], 'jobConclusion': candidate['jobConclusion']}
        manifest['publicationRequiredBeforeDelivery'] = True
    try:
        for name in selected:
            reserve()
            print('CAPTURE ' + name, flush=True)
            with tempfile.TemporaryDirectory(prefix='omagma-video0219-' + name + '-') as temporary:
                TAKES[name](binary, Path(temporary), out, manifest)
            write_json(out / 'capture-manifest.json', manifest)
            print('CAPTURE PASS ' + name, flush=True)
    except Exception:
        manifest['failure'] = traceback.format_exc()
        write_json(out / 'capture-manifest.json', manifest)
        raise
    print('Captured native UI with fictional providers: ' + ', '.join(selected))


if __name__ == '__main__':
    main()
