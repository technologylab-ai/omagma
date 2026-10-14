#!/usr/bin/env python3
"""Capture actual meeting reminders in Mail, using a fixture-only clock.

The clock moves explicitly between before and during the same fictional event.
No desktop input, real account, system-clock change or provider write is used.
"""
from __future__ import annotations

import argparse
from datetime import timedelta
import hashlib
import json
import sys
import tempfile
from pathlib import Path

from capture_calendar import (
    ROOT, KNOWN, WORK, HERO, HERO_URL, INVITE, ACCOUNTS, StoryFixture, Recorder, Client,
    read_build_info, require, reserve, stable, native_join_proof, provider_state,
    save, write_json,
)


def set_clock(fixture, value):
    path = fixture.root / 'calendar-notification-now-ms'
    temporary = path.with_suffix('.pending')
    temporary.write_text(str(int(value.timestamp() * 1000)) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'video/cache/short029/revision-07/notifications')
    args = parser.parse_args()
    reserve()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'notification capture binary changed')
    info = {'sha256': digest, **read_build_info(binary)}
    out = args.out.resolve()
    require(not (out / 'notifications.json').exists(), 'preserve previous notification take')
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omagma-film029-notifications-') as temporary:
        directory = Path(temporary)
        fixture = StoryFixture(directory)
        fixture.seed(binary)
        # The default provider has a 09:00 meeting in each account. This take
        # tells one continuous story, so explicitly seed the other accounts
        # with no appointments instead of inheriting unrelated sample events.
        with Client(binary, directory, extra=fixture.options()) as client:
            for account in ACCOUNTS:
                client.request('calendar.list', account)
        for path in (directory / 'cache').rglob('calendar-provider-fixture.json'):
            state = json.loads(path.read_text())
            if state['account'] != WORK:
                state['events'] = []
                write_json(path, state)
        before = fixture.today + timedelta(hours=9, minutes=19)
        upcoming = fixture.today + timedelta(hours=9, minutes=20)
        during = fixture.today + timedelta(hours=9, minutes=45)
        set_clock(fixture, before)
        rec = Recorder(binary, directory, 'notifications', columns=132, rows=28,
                       extra=(*fixture.options(), '--account', WORK, '--ui-file', str(fixture.preferences)))
        try:
            rec.wait(lambda: 'Up to date' in rec.text() and INVITE in rec.text())
            rec.gap(2.2)
            require('Upcoming meeting' not in rec.text() and 'Meeting now' not in rec.text(),
                    'pre-arrival frame already contains a reminder')
            stable(rec, 'mail')
            set_clock(fixture, upcoming)
            rec.wait(lambda: HERO in rec.text() and 'Starts in 10 min' in rec.text(), seconds=25)
            require('Inbox' in rec.text(), 'reminder did not arrive over Mail')
            stable(rec, 'upcoming')
            set_clock(fixture, during)
            rec.wait(lambda: HERO in rec.text() and '45 min remaining' in rec.text(), seconds=10)
            stable(rec, 'ongoing')
            rec.press('M', 'notification:focus')
            rec.gap(.3)
            stable(rec, 'focused')
            rec.press('o', 'notification:join')
            rec.wait(lambda: 'Profile 1' in rec.text() and 'Join' in rec.text())
            stable(rec, 'profile')
            finish = rec.finish(expected_sends=0, client_extra=fixture.options())
            with Client(binary, directory, extra=fixture.options()) as client:
                require(provider_state(client, WORK)['writes'] == 0, 'notification changed Calendar')
            proof = native_join_proof(binary, directory, fixture, HERO_URL)
            tape = rec.tape(info)
            save(out / 'notifications.json', tape, known=KNOWN)
            # Specific card geometry is derived from actual completed terminal
            # cells after the visual design has been reviewed.
            assets = {'notification.' + mark: {'tape': 'notifications.json', 'mark': mark,
                       'rois': {'full': [0, 0, 1, 1]}}
                      for mark in ('mail', 'upcoming', 'ongoing', 'focused', 'profile')}
            write_json(out / 'capture-manifest.json', {
                'schema': 'omagma.video.capture.v1', 'captureRevision': '07', 'binary': info,
                'columns': 132, 'rows': 28, 'syntheticOnly': True, 'physicalDesktopUsed': False,
                'liveProviderWrites': 0, 'fixtureSends': 0, 'calendarWrites': 0,
                'automaticArrivalInMail': True, 'minuteTransitionVerified': True,
                'clockStates': {'mail': before.isoformat(), 'upcoming': upcoming.isoformat(),
                                'ongoing': during.isoformat()},
                'clockExplanation': 'Fixture clock advanced; film marks the jump to During the meeting.',
                'joinEvent': HERO, 'joinUrl': HERO_URL, 'nativeJoinProof': proof,
                'actions': [mark for mark in tape['marks'] if 'keys' in mark],
                'assets': assets, 'allOwnedPtyAndCliChildrenReaped': True, 'passed': True, **finish,
            })
            print('Captured automatic Mail reminder, before/during time and profile-aware Join', flush=True)
        finally:
            if sys.exc_info()[0]:
                print(rec.text(), file=sys.stderr)
                save(out / 'notifications-failed.json', rec.tape(info), known=KNOWN)
            rec.close()


if __name__ == '__main__':
    main()
