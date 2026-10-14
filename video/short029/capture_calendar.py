#!/usr/bin/env python3
"""Genuine 0.2.9 story captures in owned PTYs; fictional providers only.

Run under HOST_TOKEN with the frozen release candidate. This authoring helper
seeds provider-shaped examples, sends actual TUI input, and saves unchanged
completed terminal frames. It never uses the desktop or production accounts.
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
from terminal_calendar import Invitations, provider_state

WORK = ACCOUNTS[1]
KNOWN = (*ACCOUNTS, 'maya@example.org', 'leo@example.net', 'launch-rehearsal@example.org')
INVITE = 'Launch rehearsal'
FOLLOW = 'The final details for launch day'
DRAFT = 'Launch notes — a little more room to think'
HERO = 'Design review'
HERO_URL = 'https://meet.example.org/ember-design'
INVITE_ID = 'launch-invitation'
FOLLOW_ID = 'launch-details'


def reserve():
    lock = owner()
    who = identity(lock) if lock else None
    require(lock and lock.get('token') == os.environ.get('HOST_TOKEN') and who
            and start_ticks(who[0]) == who[1], 'matching live host reservation required')


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


def part(kind, text, filename='', index='0'):
    raw = text.encode()
    return {'partId': index, 'mimeType': kind, 'filename': filename,
            'headers': [{'name': 'Content-Type', 'value': kind + '; charset=utf-8'}],
            'body': {'size': len(raw), 'data': base64.urlsafe_b64encode(raw).decode().rstrip('=')}}


class StoryFixture:
    def __init__(self, directory):
        self.directory = directory
        self.root = directory / 'provider'
        (self.root / 'accounts').mkdir(parents=True, mode=0o700)
        self.today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        config = json.loads((ROOT / 'tests/fixtures/all-accounts.json').read_text())
        for row in config['accounts']:
            row.update(senderName='Morgan Hills', signature='Morgan Hills\nEmber Studio')
        self.config = directory / 'synthetic-config.json'
        write_json(self.config, config)
        self.preferences = directory / 'story-ui.json'
        write_json(self.preferences, {'schema': 1, 'theme': 'omagma', 'readerLayout': 'right',
                                     'lastAccount': WORK, 'sendGraceSeconds': 10})
        for account in ACCOUNTS:
            messages = []
            content = [
                (INVITE_ID, INVITE, 'Maya Chen <maya@example.org>',
                 'Hi Morgan,\n\nLet’s give the launch one calm rehearsal.\n\nWe’ll walk through the story, try the demo, and leave a little room for questions.\n\nSee you at 14:30!\nMaya\n'),
                (FOLLOW_ID, FOLLOW, 'Maya Chen <maya@example.org>',
                 'Hi Morgan,\n\nThe release notes are ready. Could you check the last two screenshots before we share them?\n\nA small checklist\n• Confirm the opening shot\n• Add the team’s final notes\n• Share the finished link\n\nNo rush — a reminder for later today is perfect.\nMaya\n'),
                ('design-notes', 'A quieter workspace, a clearer story', 'Leo Park <leo@example.net>',
                 'Hi Morgan,\n\nThe new visual direction is ready for our design review.\nWarm colors, useful details, and room to breathe.\n\nLeo\n'),
                ('studio-week', 'This week at Ember Studio', 'Maya Chen <maya@example.org>',
                 'A short week of good work.\n\nDesign review, launch rehearsal, and Friday’s studio show-and-tell.\n'),
                ('coffee', 'Coffee after the launch?', 'Leo Park <leo@example.net>',
                 'Let’s take a little time to celebrate.\nThe corner café, Friday at four.\n'),
            ]
            for index, (ident, subject, sender, body) in enumerate(content):
                msg = Invitations.message(account, 4, False)
                msg.update(id=ident, threadId=ident + '-thread', internalDate=str(int(self.today.timestamp() * 1000) + 8 * 3600000 - index * 1800000),
                           snippet=body.split('\n\n')[1] if '\n\n' in body else body, labelIds=['INBOX'] + (['UNREAD'] if index < 2 else []))
                headers = [{'name': 'From', 'value': sender}, {'name': 'To', 'value': account},
                           {'name': 'Subject', 'value': subject}, {'name': 'Message-ID', 'value': f'<{ident}@example.org>'}]
                if ident == INVITE_ID:
                    begin = (self.today + timedelta(hours=14, minutes=30)).strftime('%Y%m%dT%H%M%SZ')
                    end = (self.today + timedelta(hours=15)).strftime('%Y%m%dT%H%M%SZ')
                    ics = '\r\n'.join(['BEGIN:VCALENDAR', 'VERSION:2.0', 'METHOD:REQUEST', 'BEGIN:VEVENT',
                        'UID:launch-rehearsal@example.org', 'DTSTAMP:' + self.today.strftime('%Y%m%dT080000Z'),
                        'SEQUENCE:1', 'SUMMARY:' + INVITE, 'DTSTART:' + begin, 'DTEND:' + end,
                        'ORGANIZER;CN=Maya Chen:mailto:maya@example.org',
                        f'ATTENDEE;CN=Morgan Hills;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:{account}',
                        'LOCATION:Ember Studio · Online',
                        'DESCRIPTION:A calm run-through of the story and demo. Bring your last questions.',
                        'CONFERENCE:https://meet.example.org/ember-launch',
                        'URL:https://meet.example.org/ember-launch', 'END:VEVENT', 'END:VCALENDAR', ''])
                    msg['payload'] = {'partId': '', 'mimeType': 'multipart/mixed', 'filename': '', 'headers': headers,
                                      'body': {'size': 0}, 'parts': [part('text/plain', body), part('text/calendar', ics, 'invitation.ics', '1')]}
                else:
                    msg['payload'] = {**part('text/plain', body), 'headers': headers}
                messages.append(msg)
            write_json(self.root / 'accounts' / (account.split('@')[0] + '.json'),
                       {'account': account, 'generation': 500, 'sync': {'historyId': '500', 'history': []},
                        'identities': [{'address': account, 'name': 'Morgan Hills', 'signature': 'Morgan Hills\nEmber Studio', 'isDefault': True}],
                        'messages': messages})

    def options(self):
        return ('--fixture-root', str(self.root), '--prefetch-bodies', '0', '--config', str(self.config))

    def seed(self, binary):
        with Client(binary, self.directory, extra=self.options()) as client:
            for account in ACCOUNTS:
                client.request('mail.refresh', account, label='INBOX', limit=30, prefetchLimit=5)
                client.request('accounts.identities', account)
            client.request('calendar.list', WORK)
            state = provider_state(client, WORK)
        template = copy.deepcopy(state['events'][0])
        state['events'] = []
        working_days = [offset for offset in range(7) if (self.today + timedelta(days=offset)).weekday() < 5]
        # Two natural appointments on five visible dates, favoring weekdays.
        # Keep Design review first so the Calendar and Join chapters share it.
        pairs = [((9, 30, HERO, 60, True), (16, 0, 'Release notes', 45, False)),
                 ((10, 0, 'Product notes', 45, True), (15, 0, 'Copy workshop', 60, False)),
                 ((10, 30, 'Launch prep', 60, True), (15, 0, 'Studio show & tell', 45, True)),
                 ((9, 30, 'Creative sync', 45, True), (14, 0, 'Story workshop', 60, False)),
                 ((10, 0, 'Research catch-up', 45, True), (14, 30, 'Demo polish', 60, False))]
        if not working_days or working_days[0] != 0:
            working_days.insert(0, 0)
        schedule = [(offset, *event) for offset, pair in zip(working_days, pairs) for event in pair]
        for index, (day, hour, minute, summary, duration, joinable) in enumerate(schedule):
            item = copy.deepcopy(template)
            item['calendar_id'] = WORK
            value = item['value']
            ident = 'studio-' + str(index)
            begin = self.today + timedelta(days=day, hours=hour, minutes=minute)
            end = begin + timedelta(minutes=duration)
            value.update(id=ident, iCalUID=ident + '@example.org', summary=summary,
                         description='Warm colors. Useful details. Room to breathe.\nReview the opening story and choose the final direction.',
                         location='Ember Studio · Online', organizer={'email': 'maya@example.org', 'displayName': 'Maya Chen'},
                         attendees=[{'email': WORK, 'displayName': 'Morgan Hills', 'self': True, 'responseStatus': 'accepted'}],
                         hangoutLink=HERO_URL, htmlLink='https://calendar.example.org/event/' + ident)
            if not joinable:
                value.pop('hangoutLink', None)
                value['location'] = 'Ember Studio'
            value['start'] = {'dateTime': begin.isoformat().replace('+00:00', 'Z')}
            value['end'] = {'dateTime': end.isoformat().replace('+00:00', 'Z')}
            state['events'].append(item)
        paths = [path for path in (self.directory / 'cache').rglob('calendar-provider-fixture.json')
                 if json.loads(path.read_text())['account'] == WORK]
        require(len(paths) == 1, 'ambiguous Calendar provider fixture')
        write_json(paths[0], state)


def begin(binary, directory, fixture, name, columns, rows):
    rec = Recorder(binary, directory, name, extra=(*fixture.options(), '--account', WORK,
                   '--ui-file', str(fixture.preferences)), columns=columns, rows=rows)
    try:
        rec.wait(lambda: 'Up to date' in rec.text() and INVITE in rec.text() and 'Hi Morgan,' in rec.text())
        rec.gap(.35)
        return rec
    except BaseException:
        rec.close()
        raise


def stable(rec, name):
    rec.gap(.45)
    require(not rec.screen.synchronized, 'cannot mark a partial synchronized frame')
    require(not any(value in rec.text() for value in ('Working…', 'Loading recent-mail recipients…', 'Fetching mail body…', 'Fetching metadata…')), 'busy frame cannot be a stable story mark')
    rec.mark(name, stable=True)
    rec.gap(.5)


def calendar_wait(rec, view='Agenda'):
    rec.wait(lambda: 'Calendar · ' + view in rec.text() and ('Up to date' in rec.text() or 'Saved calendar' in rec.text()))


def focused_label(rec, label):
    """Check the current highlighted cells, not a remembered input count.

    StoryFixture explicitly selects the built-in Omagma palette. Its focused
    controls and navigation rows use the same RGB selection background.
    """
    if rec.screen.synchronized:
        return False
    point = rec.screen.locate(label)
    if point is None:
        return False
    x, y = point['column'], point['row']
    return rec.screen.styles[y][x][1] == ('rgb', 57, 43, 48)


def focus_navigation(rec, label, prefix):
    rec.press('hh', prefix + ':focus-sidebar', show=False)
    rec.wait(lambda: 'j/k Navigate' in rec.text() and rec.screen.locate(label) is not None)
    # Reset and walk only this owned TUI's sidebar; stop on its painted focus.
    rec.press('k' * 32, prefix + ':sidebar-start', show=False)
    rec.gap(.1)
    for _ in range(32):
        if focused_label(rec, label):
            break
        rec.press('j', prefix + ':sidebar-next', show=False)
        rec.gap(.06)
    rec.wait(lambda: focused_label(rec, label), name=prefix + ':sidebar-focus-verified')


def search(rec, subject):
    rec.press('/subject:"' + subject + '"\r', 'mail:find', show=False)
    rec.wait(lambda: subject in rec.text() and 'Up to date' in rec.text())
    rec.gap(.5)


def calendar_take(rec, fixture):
    stable(rec, 'mail')
    rec.wait(lambda: 'Calendar · C' in rec.text() and 'Follow-ups' in rec.text())
    stable(rec, 'sidebar-overview')
    focus_navigation(rec, 'Calendar · C', 'calendar')
    stable(rec, 'sidebar')
    rec.press('\r', 'calendar:open-sidebar-entry')
    calendar_wait(rec)
    stable(rec, 'agenda')
    rec.press('3', 'calendar:week')
    calendar_wait(rec, 'Week')
    stable(rec, 'week')
    rec.press('?', 'calendar:help')
    rec.wait(lambda: 'Calendar · keyboard & mouse' in rec.text() and 'VIEWS & NAVIGATION' in rec.text())
    stable(rec, 'help')
    rec.press('\x1b', 'calendar:close-help', show=False)
    calendar_wait(rec, 'Week')
    rec.press('1', 'calendar:agenda')
    calendar_wait(rec)
    rec.press('/Design\r', 'calendar:find', show=False)
    rec.wait(lambda: 'Filter: Design' in rec.text())
    rec.press('\r', 'calendar:event')
    rec.wait(lambda: 'Calendar · Event' in rec.text() and HERO in rec.text() and '[o Join]' in rec.text())
    stable(rec, 'card')
    stable(rec, 'join-card')
    rec.press('o', 'calendar:join-profile')
    rec.wait(lambda: 'Join target validated' in rec.text() and 'Profile 1' in rec.text())
    stable(rec, 'join-profile')
    return {'fixtureSends': 0, 'calendarWrites': 0, 'joinEvent': HERO,
            'joinAccount': WORK, 'joinProfile': 'Profile 1', 'joinUrl': HERO_URL, 'browserLaunch': 'fixture dry-run'}


def rsvp_take(rec, fixture):
    stable(rec, 'invitation')
    rec.press('I', 'rsvp:respond')
    rec.wait(lambda: 'Meeting · review reply' in rec.text() and '[a Accept]' in rec.text()
             and 'adds supported events to your primary calendar' in rec.text())
    rec.wait(lambda: focused_label(rec, '[Esc Cancel]'))
    stable(rec, 'review-opened')
    rec.press('\t', 'rsvp:focus-accept', show=False)
    rec.wait(lambda: focused_label(rec, '[a Accept]') and not focused_label(rec, '[t Tentative]'),
             name='rsvp:accept-focus-verified')
    stable(rec, 'accept-focus')
    stable(rec, 'review')
    rec.press('\r', 'rsvp:accept')
    rec.wait(lambda: 'RSVP sent' in rec.text() and 'Calendar updated with your response' in rec.text())
    stable(rec, 'accepted')
    rec.press('I', 'rsvp:confirmed-detail', show=False)
    rec.wait(lambda: 'Your confirmed RSVP: ACCEPTED' in rec.text() and 'Working…' not in rec.text())
    stable(rec, 'confirmed')
    rec.press('\x1b', 'rsvp:back', show=False)
    rec.gap(.2)
    rec.press('C', 'rsvp:calendar')
    calendar_wait(rec)
    rec.press('/Launch\r', 'rsvp:find-event', show=False)
    rec.wait(lambda: 'Filter: Launch' in rec.text() and INVITE in rec.text())
    stable(rec, 'calendar-list')
    rec.press('\r', 'rsvp:open-event')
    rec.wait(lambda: 'Calendar · Event' in rec.text() and INVITE in rec.text() and '[o Join]' in rec.text())
    stable(rec, 'calendar')
    return {'fixtureSends': 1, 'calendarWrites': 1, 'confirmedResponse': 'ACCEPTED',
            'acceptControlVerifiedFromCells': True}


def followup_take(rec, fixture):
    search(rec, FOLLOW)
    rec.wait(lambda: 'The release notes are ready.' in rec.text())
    stable(rec, 'message')
    rec.press('b', 'followup:set')
    rec.wait(lambda: 'Date YYYY-MM-DD' in rec.text() and 'Tomorrow' in rec.text())
    stable(rec, 'schedule')
    rec.click(*rec.locate('Today'), 'followup:today')
    rec.wait(lambda: 'Date YYYY-MM-DD: ' + fixture.today.date().isoformat() in rec.text()
             and focused_label(rec, 'Today'))
    stable(rec, 'today')
    rec.press('\x13', 'followup:save')
    rec.wait(lambda: 'Local follow-up saved' in rec.text() and 'Date YYYY-MM-DD' not in rec.text())
    stable(rec, 'saved')
    focus_navigation(rec, 'Follow-ups', 'followup')
    stable(rec, 'sidebar')
    rec.press('\r', 'followup:open-sidebar-entry')
    rec.wait(lambda: '1 due · local to this computer' in rec.text() and FOLLOW in rec.text())
    stable(rec, 'list')
    return {'fixtureSends': 0, 'calendarWrites': 0, 'localReminders': 1, 'dueDate': fixture.today.date().isoformat()}


def gmail_take(rec, fixture):
    rec.press('h', 'draft:navigation', show=False)
    rec.wait(lambda: rec.screen.locate('Drafts') is not None)
    rec.click(*rec.locate('Drafts'), 'draft:list')
    rec.wait(lambda: DRAFT in rec.text())
    rec.press('\r', 'draft:open')
    rec.wait(lambda: 'Ctrl+S' in rec.text() and 'A good launch' in rec.text())
    rec.gap(.6)
    # The native background recipient lookup leaves its last status text behind.
    # A real read-only handoff inspection and Back produces calm composer status.
    rec.press(':gmail-draft\r', 'draft:inspect-local-state', show=False)
    rec.wait(lambda: 'Upload once' in rec.text())
    rec.press('\x1b', 'draft:back-to-local-state', show=False)
    rec.wait(lambda: 'Local draft · no mail sent' in rec.text() and 'Upload once' not in rec.text())
    stable(rec, 'compose')
    rec.press(':gmail-draft\r', 'draft:continue')
    rec.wait(lambda: 'Upload once' in rec.text())
    stable(rec, 'continue')
    rec.press('j', 'draft:focus-upload', show=False)
    rec.wait(lambda: focused_label(rec, 'Upload once · pause local edits'), name='draft:upload-focus-verified')
    stable(rec, 'upload-focus')
    rec.press('\r', 'draft:upload-once')
    rec.wait(lambda: 'Draft is available in Gmail' in rec.text())
    stable(rec, 'handoff')
    rec.press('\x1b', 'draft:return', show=False)
    rec.wait(lambda: 'paused in Gmail' in rec.text() and 'Continue in Gmail' not in rec.text())
    stable(rec, 'paused')
    return {'fixtureSends': 0, 'calendarWrites': 0, 'gmailDraftUploads': 1, 'localEditsPaused': True}


def native_join_proof(binary, directory, fixture, url=HERO_URL):
    """Exercise the same native profile route with an argv-recording fake Chrome.

    The story's o key uses the app's fixture dry-run. This separate proof verifies
    the native launch path without connecting a browser or an external service.
    """
    launch_root = directory / 'join-proof'
    launch_root.mkdir(mode=0o700)
    profile_root = launch_root / 'chrome-data'
    (profile_root / 'Profile 1').mkdir(parents=True)
    argv_path = launch_root / 'argv.json'
    executable = launch_root / 'synthetic-chrome'
    executable.write_text(f'#!{sys.executable}\nimport json, pathlib, sys\n'
                          f'pathlib.Path({str(argv_path)!r}).write_text(json.dumps(sys.argv[1:]))\n')
    executable.chmod(0o700)
    configuration = json.loads(fixture.config.read_text())
    configuration.update(chrome=str(executable), chromeUserData=str(profile_root))
    config_path = launch_root / 'config.json'
    write_json(config_path, configuration)
    with Client(binary, launch_root, fixtures=False, extra=('--config', str(config_path))) as client:
        result = client.request('browser.open', WORK, url=url)
        require(result['opened'] and not result['fixture'], 'native route did not launch the synthetic opener')
    deadline = time.monotonic() + 3
    while not argv_path.exists() and time.monotonic() < deadline:
        time.sleep(.01)
    require(argv_path.exists(), 'synthetic opener did not record argv')
    argv = json.loads(argv_path.read_text())
    require(argv == ['--profile-directory=Profile 1', '--user-data-dir=' + str(profile_root), url], 'native Join argv lost account profile, isolated data root or URL')
    return {'account': WORK, 'profile': 'Profile 1', 'url': url, 'actualSyntheticOpenerLaunches': 1,
            'exactArgvVerified': True, 'isolatedUserDataRootVerified': True, 'browserOrNetworkOpened': False}


ASSETS = {
    'sidebar.overview': ('calendar', 'sidebar-overview'),
    'calendar.sidebar': ('calendar', 'sidebar'),
    'calendar.agenda': ('calendar', 'agenda'), 'calendar.week': ('calendar', 'week'),
    'calendar.help': ('calendar', 'help'), 'calendar.card': ('calendar', 'card'),
    'rsvp.invitation': ('rsvp', 'invitation'), 'rsvp.review': ('rsvp', 'review'),
    'rsvp.review_opened': ('rsvp', 'review-opened'), 'rsvp.accept_focus': ('rsvp', 'accept-focus'),
    'rsvp.accepted': ('rsvp', 'accepted'), 'rsvp.confirmed': ('rsvp', 'confirmed'), 'rsvp.calendar': ('rsvp', 'calendar'),
    'join.card': ('calendar', 'join-card'), 'join.profile': ('calendar', 'join-profile'),
    'followup.message': ('followup', 'message'), 'followup.schedule': ('followup', 'schedule'),
    'followup.today': ('followup', 'today'), 'followup.saved': ('followup', 'saved'), 'followup.list': ('followup', 'list'),
    'followup.sidebar': ('followup', 'sidebar'),
    'draft.compose': ('gmail', 'compose'), 'draft.continue': ('gmail', 'continue'),
    'draft.upload_focus': ('gmail', 'upload-focus'), 'draft.handoff': ('gmail', 'handoff'), 'draft.paused': ('gmail', 'paused'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'video/cache/short029/revision-02/calendar')
    parser.add_argument('--scene', choices=('calendar', 'rsvp', 'followup', 'gmail'))
    parser.add_argument('--columns', type=int, default=156)
    parser.add_argument('--rows', type=int, default=42)
    args = parser.parse_args()
    reserve()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'capture binary changed')
    info = {'sha256': digest, **read_build_info(binary)}
    out = args.out.resolve()
    require(out != (ROOT / 'video/cache/short029/calendar').resolve(), 'revision captures must preserve the original Calendar tapes')
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / 'capture-manifest.json'
    receipt = json.loads(manifest_path.read_text()) if args.scene and manifest_path.exists() else {}
    if receipt:
        require(receipt.get('binary', {}).get('sha256') == digest, 'do not mix candidate binaries in one capture directory')
    receipt.update(schema='omagma.video.capture.v1', captureRevision='02', binary=info, syntheticOnly=True, liveProviderWrites=0,
                   physicalDesktopUsed=False, columns=args.columns, rows=args.rows)
    receipt.setdefault('scenes', {})
    for name, capture in [('calendar', calendar_take), ('rsvp', rsvp_take), ('followup', followup_take), ('gmail', gmail_take)]:
        if args.scene and name != args.scene:
            continue
        with tempfile.TemporaryDirectory(prefix='omagma-film029-' + name + '-') as temporary:
            directory = Path(temporary)
            fixture = StoryFixture(directory)
            fixture.seed(binary)
            draft_id = None
            if name == 'gmail':
                with Client(binary, directory, extra=fixture.options()) as client:
                    draft = client.request('draft.create', WORK, draft={
                        'to': [{'address': 'maya@example.org', 'name': 'Maya Chen'}], 'subject': DRAFT,
                        'bodyText': '# A good launch starts with a clear story\n\nHi Maya,\n\nThe first draft is ready.\n\n- A calmer inbox\n- A week you can see\n- One less detail to remember\n\nI’ll polish the ending on my phone after the rehearsal.\n\nMorgan',
                        'bodyFormat': 'markdown'})
                    draft_id = draft['id']
            rec = begin(binary, directory, fixture, name, args.columns, args.rows)
            try:
                result = capture(rec, fixture)
                result.update(rec.finish(expected_sends=result['fixtureSends'], client_extra=fixture.options()))
                with Client(binary, directory, extra=fixture.options()) as client:
                    require(provider_state(client, WORK)['writes'] == result['calendarWrites'], 'unexpected Calendar mutation count')
                    if name == 'rsvp':
                        inspected = client.request('invitation.inspect', WORK, messageId=INVITE_ID, cacheOnly=True)
                        require(inspected['confirmedResponse'] == 'ACCEPTED' and inspected['calendarSync']['state'] == 'applied', 'RSVP/Calendar result not durable')
                    if name == 'followup':
                        reminders = client.request('reminder.list', WORK)['entries']
                        require(len(reminders) == 1 and reminders[0]['messageId'] == FOLLOW_ID and reminders[0]['dueDate'] == result['dueDate'], 'wrong follow-up target/date')
                    if name == 'gmail':
                        stored = client.request('draft.read', WORK, draftId=draft_id)
                        require(stored['gmailLink']['paused'] and stored['bodyText'] == draft['bodyText'], 'Gmail handoff lost local source or pause')
                if name == 'calendar':
                    result['nativeJoinProof'] = native_join_proof(binary, directory, fixture)
                tape = rec.tape(info)
                save(out / (name + '.json'), tape, known=KNOWN)
                result.update(tape=name + '.json', marks=[mark for mark in tape['marks'] if mark.get('stable')],
                              actions=[mark for mark in tape['marks'] if 'keys' in mark or 'click' in mark],
                              allOwnedChildrenReaped=True)
                receipt['scenes'][name] = result
                receipt['assets'] = {key: {'tape': scene + '.json', 'mark': mark, 'rois': {'full': [0, 0, 1, 1], 'focus': [0, 0, 1, 1]},
                                          'provenance': 'Actual native PTY cells; fictional provider; synchronized complete frame'}
                                     for key, (scene, mark) in ASSETS.items() if scene in receipt['scenes']}
                receipt['fixtureSends'] = sum(row['fixtureSends'] for row in receipt['scenes'].values())
                write_json(manifest_path, receipt)
                print('Captured', name, flush=True)
            finally:
                if sys.exc_info()[0]:
                    print(rec.text(), file=sys.stderr)
                    save(out / (name + '-failed.json'), rec.tape(info), known=KNOWN)
                rec.close()


if __name__ == '__main__':
    main()
