#!/usr/bin/env python3
"""Capture native Calendar release workflows in owned synthetic PTYs.

The actual frozen executable supplies every recorded cell. The authoring
fixture contains only example identities; no desktop, browser or live provider
is used. Run under the cooperating host reservation supplied as HOST_TOKEN.
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
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'video/capture'), str(ROOT / 'tests'), str(ROOT / 'video/tools')]
from tape import Recorder, save
from host_lock import owner, identity, start_ticks
from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, require
from terminal_calendar import provider_state

WORK = ACCOUNTS[1]
HERO = 'Roadmap review'
MAYA = 'maya@example.org'
LEO = 'leo@example.net'
KNOWN = (*ACCOUNTS, MAYA, LEO, 'studio@example.org', 'calendar-owner@example.org', 'nora@example.org')
MEET = 'https://meet.google.com/abc-defg-hij'


def reserve():
    lock = owner()
    who = identity(lock) if lock else None
    require(lock and lock.get('token') == os.environ.get('HOST_TOKEN') and who
            and start_ticks(who[0]) == who[1], 'matching live host reservation required')


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


class CalendarStory:
    def __init__(self, directory):
        self.directory = directory
        self.root = directory / 'provider'
        (self.root / 'accounts').mkdir(parents=True, mode=0o700)
        (self.root / 'contacts').mkdir(mode=0o700)
        today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        self.monday = today + timedelta(days=(7 - today.weekday()) % 7)
        if self.monday <= today:
            self.monday += timedelta(days=7)
        self.hero_day = (self.monday + timedelta(days=1)).date().isoformat()
        self.offsite_day = (self.monday + timedelta(days=3)).date().isoformat()
        config = json.loads((ROOT / 'tests/fixtures/all-accounts.json').read_text())
        for account in config['accounts']:
            account.update(senderName='Morgan Hills', signature='Morgan Hills\nEmber Studio')
        self.config = directory / 'story-config.json'
        write_json(self.config, config)
        self.preferences = directory / 'story-ui.json'
        shown = {(ACCOUNTS[0], ACCOUNTS[0]): 'blue', (WORK, WORK): 'orange',
                 (WORK, 'fixture-shared-team'): 'cyan', (WORK, 'fixture-readonly'): 'green',
                 (ACCOUNTS[2], ACCOUNTS[2]): 'magenta'}
        choices = [{'account': account, 'calendarId': calendar, 'visible': (account, calendar) in shown,
                    'color': shown.get((account, calendar), 'foreground')}
                   for account in ACCOUNTS for calendar in (account, 'fixture-shared-team', 'fixture-readonly')]
        write_json(self.preferences, {'schema': 1, 'theme': 'omagma', 'readerLayout': 'right',
                    'lastAccount': WORK, 'calendar': {'scope': 'all_accounts', 'sources': choices}})
        content = [('studio-notes', 'A clear plan for next week', 'Maya Chen', MAYA,
                    'Hi Morgan,\n\nThe team is ready for our roadmap review.\nLet’s choose the next milestones and leave time for questions.\n\nMaya'),
                   ('design-direction', 'Design direction is ready', 'Leo Park', LEO,
                    'The new direction is ready to share.\nBring your notes to the review.\n\nLeo'),
                   ('team-update', 'This week at Ember Studio', 'Maya Chen', MAYA,
                    'A little planning, focused work, and a good conversation.\n\nSee you next week!')]
        for account in ACCOUNTS:
            messages = []
            for index, (ident, subject, name, email, body) in enumerate(content):
                data = body.encode()
                messages.append({'id': ident, 'threadId': ident + '-thread', 'historyId': '500',
                    'internalDate': str(int(today.timestamp() * 1000) + 8 * 3600000 - index * 1800000),
                    'labelIds': ['INBOX'] + (['UNREAD'] if index == 0 else []), 'snippet': body,
                    'sizeEstimate': len(data) + 500,
                    'payload': {'partId': '', 'mimeType': 'text/plain', 'filename': '',
                        'headers': [{'name': 'From', 'value': f'{name} <{email}>'}, {'name': 'To', 'value': account},
                                    {'name': 'Subject', 'value': subject}, {'name': 'Content-Type', 'value': 'text/plain; charset=utf-8'}],
                        'body': {'size': len(data), 'data': base64.urlsafe_b64encode(data).decode().rstrip('=')}}})
            write_json(self.root / 'accounts' / (account.split('@')[0] + '.json'),
                       {'account': account, 'generation': 500, 'sync': {'historyId': '500', 'history': []},
                        'identities': [{'address': account, 'name': 'Morgan Hills', 'signature': 'Morgan Hills\nEmber Studio', 'isDefault': True}],
                        'messages': messages})
            connections = []
            for ident, given, family, email in [('maya', 'Maya', 'Chen', MAYA), ('leo', 'Leo', 'Park', LEO),
                                              ('nora', 'Nora', 'Santos', 'nora@example.org')]:
                connections.append({'resourceName': 'people/' + ident, 'etag': 'contact-' + ident,
                    'metadata': {'sources': [{'type': 'CONTACT', 'id': ident, 'etag': 'source-' + ident}]},
                    'names': [{'displayName': given + ' ' + family, 'givenName': given, 'familyName': family}],
                    'emailAddresses': [{'value': email, 'type': 'work'}]})
            write_json(self.root / 'contacts' / (account.split('@')[0] + '.json'), {'account': account, 'connections': connections})
        self.contacts_before = None
        self.review_proof = []

    def options(self):
        return ('--fixture-root', str(self.root), '--prefetch-bodies', '0', '--config', str(self.config))

    def seed(self, binary):
        states = {}
        with Client(binary, self.directory, extra=self.options()) as client:
            for account in ACCOUNTS:
                client.request('mail.refresh', account, label='INBOX', limit=30, prefetchLimit=3)
                client.request('accounts.identities', account)
                client.request('calendar.list', account)
                states[account] = provider_state(client, account)
                states[account]['events'] = []
            self.contacts_before = client.request('contacts.list', WORK)
        plan = [
            (WORK, 'fixture-shared-team', 0, 9, 0, 180, 'Studio focus', False),
            (WORK, WORK, 0, 10, 30, 45, 'Design check-in', True),
            (WORK, 'fixture-shared-team', 0, 10, 20, 50, 'Release review', True),
            (ACCOUNTS[0], ACCOUNTS[0], 0, 10, 15, 30, 'Coffee with Leo', False),
            (ACCOUNTS[2], ACCOUNTS[2], 0, 10, 10, 30, 'Product notes', False),
            (WORK, WORK, 0, 15, 0, 60, 'Client briefing', True),
            (WORK, 'fixture-shared-team', 1, 9, 0, 180, 'Planning block', False),
            (WORK, 'fixture-shared-team', 1, 10, 0, 45, 'Creative sync', True),
            (ACCOUNTS[0], ACCOUNTS[0], 1, 10, 15, 30, 'Coffee with Maya', False),
            (ACCOUNTS[2], ACCOUNTS[2], 1, 10, 20, 30, 'Research notes', False),
            (WORK, WORK, 1, 14, 0, 60, 'Story workshop', True),
            (WORK, WORK, 2, 9, 30, 60, 'Design direction', True),
            (ACCOUNTS[2], ACCOUNTS[2], 2, 11, 0, 45, 'Product research', False),
            (WORK, 'fixture-shared-team', 2, 14, 30, 60, 'Team catch-up', True),
            (WORK, WORK, 3, 10, 0, 60, 'Launch planning', True),
            (ACCOUNTS[0], ACCOUNTS[0], 3, 13, 0, 45, 'Lunch with Leo', False),
            (WORK, 'fixture-shared-team', 3, 15, 0, 60, 'Copy workshop', False),
            (WORK, WORK, 4, 10, 0, 45, 'Friday review', True),
            (WORK, 'fixture-shared-team', 4, 14, 30, 45, 'Studio show & tell', True),
        ]
        for index, (account, calendar, offset, hour, minute, duration, title, online) in enumerate(plan):
            first = self.monday + timedelta(days=offset, hours=hour, minutes=minute)
            last = first + timedelta(minutes=duration)
            ident = 'studio-' + str(index)
            value = {'id': ident, 'iCalUID': ident + '@example.org', 'etag': '"story-1"', 'status': 'confirmed',
                'summary': title, 'description': 'Choose the next milestones, share the plan, and leave time for questions.',
                'location': 'Ember Studio', 'organizer': {'email': MAYA, 'displayName': 'Maya Chen'},
                'attendees': [{'email': account, 'self': True, 'displayName': 'Morgan Hills', 'responseStatus': 'accepted'}],
                'start': {'dateTime': first.isoformat().replace('+00:00', 'Z')},
                'end': {'dateTime': last.isoformat().replace('+00:00', 'Z')},
                'htmlLink': 'https://calendar.google.com/calendar/event?eid=' + ident}
            if online:
                value['hangoutLink'] = 'https://meet.example.org/ember-' + str(index)
            states[account]['events'].append({'calendar_id': calendar, 'value': value})
        states[WORK]['events'].append({'calendar_id': 'fixture-readonly', 'value': {
            'id': 'autumn-holiday', 'iCalUID': 'autumn-holiday@example.org', 'etag': '"holiday-1"', 'status': 'confirmed',
            'summary': 'Autumn holiday', 'organizer': {'email': 'studio@example.org'},
            'start': {'date': (self.monday + timedelta(days=2)).date().isoformat()},
            'end': {'date': (self.monday + timedelta(days=3)).date().isoformat()}}})
        for path in (self.directory / 'cache').rglob('calendar-provider-fixture.json'):
            account = json.loads(path.read_text())['account']
            write_json(path, states[account])

    def provider(self, binary):
        with Client(binary, self.directory, extra=self.options()) as client:
            return provider_state(client, WORK)

    def writes(self, binary, expected):
        with Client(binary, self.directory, extra=self.options()) as client:
            for account in ACCOUNTS:
                count = provider_state(client, account)['writes']
                require(count == (expected if account == WORK else 0), 'unexpected Calendar mutation count/account')
            require(client.request('contacts.list', WORK) == self.contacts_before, 'guest picking modified Contacts')

    def saved(self, binary, title=HERO):
        matches = [row['value'] for row in self.provider(binary)['events']
                   if row['calendar_id'] == WORK and row['value'].get('summary') == title]
        require(len(matches) == 1, 'expected exactly one saved event in Work primary')
        return matches[0]


def begin(binary, directory, fixture, name, rows=32):
    rec = Recorder(binary, directory, name, extra=(*fixture.options(), '--account', WORK,
                    '--ui-file', str(fixture.preferences)), columns=132, rows=rows)
    try:
        rec.wait(lambda: 'A clear plan for next week' in rec.text() and 'Hi Morgan,' in rec.text() and 'Up to date' in rec.text())
        rec.gap(.2)
        return rec
    except BaseException:
        rec.close()
        raise


def stable(rec, name):
    rec.gap(.22)
    require(not rec.screen.synchronized, 'stable mark requires a completed frame')
    require(not any(term in rec.text() for term in ('Working…', 'Loading calendars…', 'Loading account calendars…', 'Checking event…')),
            'stable mark cannot capture an unresolved operation')
    rec.mark(name, stable=True)
    rec.gap(.25)


def calendar_wait(rec, view='Agenda'):
    rec.wait(lambda: 'Calendar · ' + view in rec.text() and ('Up to date' in rec.text() or 'Saved calendar' in rec.text()))
    rec.gap(.08)


def open_week(rec, fixture):
    rec.press('C', 'calendar:open')
    calendar_wait(rec)
    rec.press('\x07', 'calendar:date', show=False)
    rec.wait(lambda: 'Date YYYY-MM-DD' in rec.text())
    rec.press('\x05' + '\x7f' * 12 + fixture.monday.date().isoformat() + '\r', 'calendar:week-date', show=False)
    calendar_wait(rec)
    rec.press('3', 'calendar:week')
    calendar_wait(rec, 'Week')
    rec.wait(lambda: 'Mon ' + fixture.monday.strftime('%m-%d') in rec.text() and 'Autumn' in rec.text())


def focused(rec, label):
    position = rec.screen.locate(label)
    if not position:
        return False
    return rec.screen.styles[position['row']][position['column']][1] == ('rgb', 57, 43, 48)


def row_of(rec, label):
    position = rec.screen.locate(label)
    return rec.screen.lines()[position['row']] if position else ''


def focus_field(rec, label):
    for _ in range(36):
        if '▏' in row_of(rec, label + ':'):
            return
        if rec.screen.locate(label + ':'):
            rec.click(*rec.locate(label + ':'), 'form:focus-' + label.lower().replace(' ', '-'))
            rec.wait(lambda: '▏' in row_of(rec, label + ':'))
            return
        rec.press('\t', 'form:next-field', show=False)
        rec.gap(.04)
    raise AssertionError('field is not reachable: ' + label)


def fill(rec, label, value, animate=False):
    focus_field(rec, label)
    rec.press('\x05' + '\x7f' * 128, 'form:clear-' + label.lower().replace(' ', '-'), show=False)
    rec.gap(.04)
    if animate:
        rec.type(value, 'form:type-' + label.lower(), delay=.014)
    else:
        rec.press('\x1b[200~' + value + '\x1b[201~', 'form:set-' + label.lower().replace(' ', '-'), show=False)
    rec.wait(lambda: '▏' in row_of(rec, label + ':') and (not value or value[-12:] in row_of(rec, label + ':')))


def press_visible(rec, label, result):
    for _ in range(36):
        if rec.screen.locate(label):
            rec.click(*rec.locate(label), 'control:' + label)
            rec.wait(result)
            return
        rec.press('\t', 'form:next-control', show=False)
        rec.gap(.04)
    raise AssertionError('control not reachable: ' + label)


def selected(rec, title):
    return title in rec.screen.lines()[-4]


def select_event(rec, title):
    rec.press('k' * 40, 'week:first-event', show=False)
    rec.gap(.12)
    for _ in range(40):
        if selected(rec, title):
            return
        rec.press('j', 'week:next-event', show=False)
        rec.gap(.045)
    raise AssertionError('event cannot be selected: ' + title)


def find_in_week(rec, title):
    rec.press('/' + title + '\r', 'week:find-created', show=False)
    rec.wait(lambda: 'Filter: ' + title in rec.text() and title in rec.text())


def clear_find(rec):
    rec.press('/\x1b', 'week:clear-filter', show=False)
    rec.wait(lambda: 'Filter:' not in rec.text())


def review(rec, fixture, binary, writes, mark):
    rec.press('\x13', 'event:review')
    rec.wait(lambda: 'Review new event' in rec.text() or 'Review event changes' in rec.text())
    fixture.writes(binary, writes)
    prepared = []
    for path in (fixture.directory / 'cache').rglob('calendar-state.json'):
        document = json.loads(path.read_text())
        if document.get('account') == WORK:
            prepared.extend(entry['review'] for entry in document['entries']
                            if entry.get('review') and entry['review'].get('ordinary_event'))
    require(len(prepared) == 1, 'review did not persist exactly one pending ordinary event')
    prepared = prepared[0]
    draft = prepared['ordinary_event']['draft']
    updates = prepared['ordinary_event']['send_updates']
    require('sendUpdates=' + updates in prepared['request']['url'], 'prepared request disagrees with guest email policy')
    fixture.review_proof.append({'title': draft['summary'], 'sendUpdates': updates,
                                 'requestPolicyVerified': True, 'providerWritesBeforeConfirm': writes})
    # Reach the end using ordinary read-only scrolling, then mark the exact
    # enabled confirmation and the visible guest notification policy.
    for _ in range(18):
        rec.press('j', 'review:scroll', show=False)
        rec.gap(.008)
    stable(rec, mark)


def confirm(rec, fixture, binary, writes, mark):
    rec.press('y', 'event:confirm')
    rec.wait(lambda: 'Event saved' in rec.text() and '[Esc Back to Calendar]' in rec.text())
    fixture.writes(binary, writes)
    stable(rec, mark)


def leave_saved(rec):
    rec.press('\x1b', 'event:back-to-calendar', show=False)
    rec.wait(lambda: 'Event saved' not in rec.text() and 'Calendar · Week' in rec.text())
    rec.gap(.18)


def add_contact(rec, name, email, mark):
    focus_field(rec, 'Guests')
    rec.press('\x00', 'guests:contacts')
    rec.wait(lambda: 'Add a guest from Contacts' in rec.text() and MAYA in rec.text() and LEO in rec.text())
    if mark and name != 'Leo':
        stable(rec, mark)
    rec.type(name, 'guests:find-' + name.lower(), delay=.015)
    rec.wait(lambda: email in rec.text())
    if mark and name == 'Leo':
        stable(rec, mark)
    rec.press('\r', 'guests:add-' + name.lower())
    rec.wait(lambda: 'Add a guest from Contacts' not in rec.text() and email in row_of(rec, 'Guests:'))


def main_take(rec, fixture, binary):
    open_week(rec, fixture)
    stable(rec, 'week.overview')
    rec.press('g', 'sources:open')
    rec.wait(lambda: 'Show calendars · all accounts' in rec.text() and '[Enter Apply]' in rec.text())
    stable(rec, 'sources.all')
    # Exact Work shared calendar E, from the real source picker.
    rec.press('k' * 20 + 'j' * 4, 'sources:work-team', show=False)
    rec.gap(.15)
    rec.press('p', 'sources:priority')
    rec.wait(lambda: '* Priority' in rec.text())
    stable(rec, 'sources.priority')
    rec.press('\r', 'sources:apply')
    calendar_wait(rec, 'Week')
    rec.wait(lambda: 'E*' in rec.text())
    stable(rec, 'week.priority')
    select_event(rec, 'Studio focus')
    rec.press(' ', 'week:show-alternatives')
    rec.wait(lambda: 'Calendar · Events here' in rec.text() and 'Release review' in rec.text())
    stable(rec, 'week.alternatives')
    # Chronological snapshot: Studio focus09:00,Product10:10,Coffee10:15,
    # Release10:20,Design10:30. Choosing Design proves a hidden new event.
    rec.press('j' * 4, 'week:choose-design', show=False)
    rec.gap(.15)
    rec.press('\r', 'week:reveal-selected')
    rec.wait(lambda: 'Calendar · Week' in rec.text() and selected(rec, 'Design check-in'))
    stable(rec, 'week.revealed')
    rec.press('n', 'event:new')
    rec.wait(lambda: 'New event' in rec.text() and 'Title:' in rec.text())
    # Ensure the form's exact destination is Work primary; chosen-event account
    # never changes the global Mail account.
    press_visible(rec, '[Calendar:', lambda: 'Choose destination calendar' in rec.text())
    rec.press('k' * 20 + 'j' * 3, 'event:choose-work', show=False)
    rec.gap(.12)
    rec.press('\r', 'event:bind-work')
    rec.wait(lambda: 'New event' in rec.text() and WORK in rec.text())
    fill(rec, 'Title', HERO, animate=True)
    fill(rec, 'Start date', fixture.hero_day)
    fill(rec, 'End date', fixture.hero_day)
    fill(rec, 'Start time', '10:30')
    fill(rec, 'End time', '11:15')
    fill(rec, 'Time zone', 'UTC')
    fill(rec, 'Location', 'Ember Studio · Online')
    fill(rec, 'Notes', 'Choose the next milestones and share the plan.')
    stable(rec, 'event.new')
    add_contact(rec, 'Maya', MAYA, 'event.contacts')
    stable(rec, 'event.guests-first')
    add_contact(rec, 'Leo', LEO, 'event.contacts-leo')
    stable(rec, 'event.guests')
    press_visible(rec, 'Video: None', lambda: 'Video: Generate Google Meet link' in rec.text())
    stable(rec, 'event.meet')
    review(rec, fixture, binary, 0, 'event.review')
    require('email 2 guests' in rec.text() and 'Google Meet' in rec.text(), 'review omitted Meet or guest consequences')
    confirm(rec, fixture, binary, 1, 'event.saved')
    created = fixture.saved(binary)
    require(created['start']['dateTime'].startswith(fixture.hero_day + 'T10:30'), 'create start changed')
    require(created['end']['dateTime'].startswith(fixture.hero_day + 'T11:15'), 'create end changed')
    require({guest['email'] for guest in created['attendees']} == {MAYA, LEO}, 'create guests differ from chosen contacts')
    conference = created.get('conferenceData', {})
    require(conference.get('createRequest', {}).get('conferenceSolutionKey', {}).get('type') == 'hangoutsMeet'
            and created.get('hangoutLink') == MEET, 'actual provider did not create Google Meet')
    leave_saved(rec)
    clear_find(rec)
    select_event(rec, HERO)
    stable(rec, 'week.created')
    rec.press('\r', 'event:open-created')
    rec.wait(lambda: 'Calendar · Event' in rec.text() and HERO in rec.text() and MEET in rec.text())
    stable(rec, 'event.detail')
    rec.press('e', 'event:edit')
    rec.wait(lambda: 'Edit event' in rec.text() and '10:30' in rec.text())
    fill(rec, 'Start time', '11:30')
    fill(rec, 'End time', '12:15')
    # Existing participants require an explicit notification choice.
    press_visible(rec, 'Notify guests:', lambda: '[x] Email guests about these changes' in rec.text())
    stable(rec, 'event.edit')
    review(rec, fixture, binary, 1, 'event.edit-review')
    require('email 2 guests' in rec.text() and 'Existing meeting link is preserved.' in rec.text(), 'edit review lost notifications or preserved Meet')
    confirm(rec, fixture, binary, 2, 'event.rescheduled')
    updated = fixture.saved(binary)
    require(updated['id'] == created['id'] and updated['start']['dateTime'].startswith(fixture.hero_day + 'T11:30')
            and updated['end']['dateTime'].startswith(fixture.hero_day + 'T12:15'), 'edit changed identity or rescheduled instants')
    require(updated.get('conferenceData') == created.get('conferenceData') and updated.get('hangoutLink') == MEET,
            'reschedule replaced the existing Google Meet')
    require({guest['email'] for guest in updated['attendees']} == {MAYA, LEO}, 'reschedule changed guests')
    leave_saved(rec)
    clear_find(rec)
    select_event(rec, HERO)
    stable(rec, 'week.rescheduled')
    rec.press('\r', 'event:open-rescheduled')
    rec.wait(lambda: 'Calendar · Event' in rec.text() and HERO in rec.text() and '11:30–12:15' in rec.text())
    stable(rec, 'event.detail-rescheduled')
    rec.press('b', 'event:open-web-profile')
    rec.wait(lambda: 'Google Calendar target validated' in rec.text())
    stable(rec, 'event.web-profile')
    rec.press('O', 'calendar:open-web-profile')
    rec.wait(lambda: 'Google Calendar target validated' in rec.text())
    stable(rec, 'calendar.web-profile')
    rec.press('q', 'event:back-to-week', show=False)
    rec.wait(lambda: 'Calendar · Week' in rec.text() and selected(rec, HERO))
    rec.press('n', 'all-day:new')
    rec.wait(lambda: 'New event' in rec.text())
    # Same Work destination is selected explicitly rather than inferred from
    # whichever account happens to own the currently focused grid event.
    press_visible(rec, '[Calendar:', lambda: 'Choose destination calendar' in rec.text())
    rec.press('k' * 20 + 'j' * 3, 'all-day:choose-work', show=False)
    rec.gap(.1)
    rec.press('\r', 'all-day:bind-work')
    rec.wait(lambda: 'New event' in rec.text() and WORK in rec.text())
    fill(rec, 'Title', 'Studio offsite', animate=True)
    fill(rec, 'Start date', fixture.offsite_day)
    fill(rec, 'End date', fixture.offsite_day)
    press_visible(rec, '[ ] All day', lambda: '[x] All day' in rec.text())
    stable(rec, 'event.all-day')
    review(rec, fixture, binary, 2, 'event.all-day-review')
    confirm(rec, fixture, binary, 3, 'event.all-day-saved')
    all_day = fixture.saved(binary, 'Studio offsite')
    require(all_day['start']['date'] == fixture.offsite_day and all_day['end']['date'] == (datetime.fromisoformat(fixture.offsite_day) + timedelta(days=1)).date().isoformat(),
            'all-day did not preserve inclusive UI/exclusive provider dates')
    leave_saved(rec)
    clear_find(rec)
    select_event(rec, 'Studio offsite')
    stable(rec, 'week.all-day')
    return {'hero': {'title': HERO, 'account': WORK, 'calendarId': WORK, 'calendarName': 'Personal',
            'date': fixture.hero_day, 'timeZone': 'UTC', 'created': ['10:30', '11:15'], 'rescheduled': ['11:30', '12:15'],
            'id': updated['id'], 'guests': [{'name': 'Maya Chen', 'email': MAYA}, {'name': 'Leo Park', 'email': LEO}],
            'meetUrl': MEET, 'meetRetained': True, 'notificationPolicy': 'all'},
            'allDay': {'title': 'Studio offsite', 'start': all_day['start']['date'], 'exclusiveEnd': all_day['end']['date']},
            'calendarWrites': 3, 'contactsUnchanged': True, 'beforeConfirmationWritesVerified': True}


def native_profile_proof(binary, directory, fixture, event_id):
    with Client(binary, directory, extra=fixture.options()) as client:
        event = client.request('calendar.event-open', WORK, calendarId=WORK, eventId=event_id)
        home = client.request('calendar.open', WORK)
    urls = [event['url'], home['url']]
    require(all('authuser=work%40example.com' in url for url in urls), 'Calendar URLs lost exact owning authuser')
    proof = directory / 'profile-proof'
    proof.mkdir(mode=0o700)
    chrome_data = proof / 'chrome-data'
    (chrome_data / 'Profile 1').mkdir(parents=True)
    launches = proof / 'launches'
    launches.mkdir()
    executable = proof / 'chrome-recorder'
    executable.write_text(f'#!{sys.executable}\nimport json, os, pathlib, sys\n'
                          f'root=pathlib.Path({str(launches)!r})\n'
                          '(root/(str(os.getpid())+".json")).write_text(json.dumps(sys.argv[1:]))\n')
    executable.chmod(0o700)
    config = json.loads(fixture.config.read_text())
    config.update(chrome=str(executable), chromeUserData=str(chrome_data))
    configuration = proof / 'config.json'
    write_json(configuration, config)
    for index, url in enumerate(urls):
        with Client(binary, proof / ('client-' + str(index)), fixtures=False, extra=('--config', str(configuration))) as client:
            result = client.request('browser.open', WORK, url=url)
            require(result['opened'] and not result['fixture'] and result['profile'] == '--profile-directory=Profile 1',
                    'native opener did not use exact Work profile')
        deadline = time.monotonic() + 3
        while len(list(launches.glob('*.json'))) <= index and time.monotonic() < deadline:
            time.sleep(.01)
        argv = [json.loads(path.read_text()) for path in launches.glob('*.json')]
        require(['--profile-directory=Profile 1', '--user-data-dir=' + str(chrome_data), url] in argv,
                'native Chrome argv differed from reviewed Calendar target')
    return {'account': WORK, 'profile': 'Profile 1', 'eventUrl': urls[0], 'calendarUrl': urls[1],
            'exactNativeArgvVerified': True, 'actualSyntheticOpenerLaunches': 2, 'isolatedUserDataRootVerified': True,
            'realBrowserOpened': False, 'externalNetworkRequests': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'video/cache/short0210/revision-03')
    args = parser.parse_args()
    reserve()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'capture binary hash differs from frozen installed candidate')
    info = {'sha256': digest, **read_build_info(binary)}
    out = args.out.resolve()
    require(out.is_relative_to((ROOT / 'video/cache/short0210').resolve()), 'captures must use the new release cache directory')
    tapes = out / 'tapes'
    tapes.mkdir(parents=True, exist_ok=True)
    require(not (out / 'capture-manifest.json').exists(), 'preserve previous successful capture manifests')
    receipt = {'schema': 'omagma.video.capture.v1', 'release': '0.2.10', 'binary': info,
               'syntheticOnly': True, 'liveProviderWrites': 0, 'physicalDesktopUsed': False, 'scenes': {}, 'assets': {}}
    with tempfile.TemporaryDirectory(prefix='omagma-film0210-') as temporary:
        directory = Path(temporary)
        # Genuine taller baseline before the hero meeting exists. Its isolated
        # provider and PTY cannot inherit later creates or all-day writes.
        baseline_dir = directory / 'baseline'
        baseline_dir.mkdir(mode=0o700)
        baseline = CalendarStory(baseline_dir)
        baseline.seed(binary)
        before = begin(binary, baseline_dir, baseline, 'crowded-before', rows=48)
        try:
            open_week(before, baseline)
            before.press('g', 'sources:open', show=False)
            before.wait(lambda: 'Show calendars · all accounts' in before.text() and '[Enter Apply]' in before.text())
            before.press('k' * 20 + 'j' * 4, 'sources:work-team', show=False)
            before.gap(.15)
            before.press('p', 'sources:priority', show=False)
            before.wait(lambda: '* Priority' in before.text())
            before.press('\r', 'sources:apply', show=False)
            calendar_wait(before, 'Week')
            before.wait(lambda: 'E*' in before.text())
            require(HERO not in before.text() and 'Studio offsite' not in before.text(), 'baseline revealed future story events')
            stable(before, 'week.crowded-before')
            baseline.writes(binary, 0)
            result = before.finish(expected_sends=0, client_extra=baseline.options())
            tape = before.tape(info)
            save(tapes / 'crowded-before.json', tape, known=KNOWN)
            result.update(tape='tapes/crowded-before.json', columns=132, rows=48, calendarWrites=0,
                          heroCreated=False, allDayCreated=False, priorityAccount=WORK, priorityCalendarId='fixture-shared-team',
                          stableMarks=[mark for mark in tape['marks'] if mark.get('stable')])
            receipt['scenes']['crowded-before'] = result
            receipt['assets']['week.crowded-before'] = {'tape': result['tape'], 'mark': 'week.crowded-before', 'columns': 132, 'rows': 48,
                'rois': {'full': [0, 0, 1, 1], 'context': [0, 4 / 48, 1, 5 / 48], 'active': [0, 22 / 48, 1, 13 / 48]},
                'provenance': 'Actual pre-creation native synchronized PTY cells; priority staged through real picker; zero provider writes'}
        except BaseException:
            print(before.text(), file=sys.stderr)
            save(tapes / 'crowded-before-failed.json', before.tape(info), known=KNOWN)
            raise
        finally:
            before.close()
        fixture = CalendarStory(directory)
        fixture.seed(binary)
        rec = begin(binary, directory, fixture, 'calendar-story', rows=32)
        try:
            result = main_take(rec, fixture, binary)
            result.update(rec.finish(expected_sends=0, client_extra=fixture.options()))
            fixture.writes(binary, 3)
            result['nativeProfileProof'] = native_profile_proof(binary, directory, fixture, result['hero']['id'])
            hero_reviews = [row for row in fixture.review_proof if row['title'] == HERO]
            require(len(hero_reviews) == 2 and all(row['sendUpdates'] == 'all' for row in hero_reviews), 'prepared review lost exact guest notification policy')
            result['reviewProof'] = {'heroReviews': hero_reviews, 'bothSendUpdatesAll': True, 'providerWrites': 3, 'dispatchAttempts': fixture.provider(binary)['dispatch_attempts']}
            tape = rec.tape(info)
            save(tapes / 'calendar-story.json', tape, known=KNOWN)
            result.update(tape='tapes/calendar-story.json', columns=132, rows=32,
                          stableMarks=[mark for mark in tape['marks'] if mark.get('stable')], actions=[mark for mark in tape['marks'] if 'keys' in mark or 'click' in mark])
            receipt['scenes']['calendar-story'] = result
            for mark in result['stableMarks']:
                receipt['assets'][mark['name']] = {'tape': result['tape'], 'mark': mark['name'], 'columns': 132, 'rows': 32,
                    'rois': {'full': [0, 0, 1, 1], 'content': [0, .18, 1, .68], 'form': [.15, .035, .7, .9]},
                    'provenance': 'Actual native synchronized PTY cells; unchanged frozen binary; synthetic providers'}
        except BaseException:
            print(rec.text(), file=sys.stderr)
            save(tapes / 'calendar-story-failed.json', rec.tape(info), known=KNOWN)
            raise
        finally:
            rec.close()
        # Separate fixed-size tape: the existing recorder keeps one stable cell
        # geometry per take. No resizing, reflow or post-edited native cells.
        crowded = begin(binary, directory, fixture, 'crowded-week', rows=48)
        try:
            open_week(crowded, fixture)
            stable(crowded, 'week.crowded')
            fixture.writes(binary, 3)
            result = crowded.finish(expected_sends=0, client_extra=fixture.options())
            tape = crowded.tape(info)
            save(tapes / 'crowded-week.json', tape, known=KNOWN)
            result.update(tape='tapes/crowded-week.json', columns=132, rows=48,
                          stableMarks=[mark for mark in tape['marks'] if mark.get('stable')])
            receipt['scenes']['crowded-week'] = result
            receipt['assets']['week.crowded'] = {'tape': result['tape'], 'mark': 'week.crowded', 'columns': 132, 'rows': 48,
                'rois': {'full': [0, 0, 1, 1], 'crowded': [0, .07, .61, .64]},
                'provenance': 'Actual native synchronized PTY cells; unchanged frozen binary; synthetic providers'}
        except BaseException:
            print(crowded.text(), file=sys.stderr)
            save(tapes / 'crowded-week-failed.json', crowded.tape(info), known=KNOWN)
            raise
        finally:
            crowded.close()
    receipt['allOwnedChildrenReaped'] = True
    write_json(out / 'capture-manifest.json', receipt)
    print('Captured native0.2.10 Calendar story:', len(receipt['assets']), 'assets', flush=True)


if __name__ == '__main__':
    main()
