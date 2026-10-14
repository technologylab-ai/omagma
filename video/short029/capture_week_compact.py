#!/usr/bin/env python3
"""Recapture the same fictional week in a smaller native terminal for the film."""
import argparse
import hashlib
from pathlib import Path
import tempfile

from capture_calendar import (
    ROOT, KNOWN, WORK, HERO, StoryFixture, begin, calendar_wait, stable,
    require, reserve, Client, provider_state, read_build_info, save, write_json,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--columns', type=int, default=132)
    parser.add_argument('--rows', type=int, default=28)
    args = parser.parse_args()
    reserve()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'frozen capture binary changed')
    out = args.out.resolve()
    require(not out.exists(), 'preserve prior week captures')
    out.mkdir(parents=True)
    info = {'sha256': digest, **read_build_info(binary)}
    with tempfile.TemporaryDirectory(prefix='omagma-film029-week-') as temporary:
        directory = Path(temporary)
        fixture = StoryFixture(directory)
        fixture.seed(binary)
        rec = begin(binary, directory, fixture, 'week-compact', args.columns, args.rows)
        try:
            rec.press('C', 'calendar:open', show=False)
            calendar_wait(rec)
            rec.press('3', 'calendar:week')
            calendar_wait(rec, 'Week')
            require(HERO[:6] in rec.text(), 'selected design event missing')
            require(all(day in rec.text() for day in ['Wed', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue']), 'seven day week missing')
            stable(rec, 'week')
            rec.press('\r', 'calendar:open-selected-event')
            rec.wait(lambda: 'Calendar · Event' in rec.text() and HERO in rec.text() and '[o Join]' in rec.text())
            stable(rec, 'card')
            finish = rec.finish(expected_sends=0, client_extra=fixture.options())
            with Client(binary, directory, extra=fixture.options()) as client:
                require(provider_state(client, WORK)['writes'] == 0, 'week browse unexpectedly wrote Calendar')
            tape = rec.tape(info)
            save(out / 'week.json', tape, known=KNOWN)
            write_json(out / 'capture-manifest.json', {
                'schema': 'omagma.video.capture.v1', 'captureRevision': '04', 'binary': info,
                'columns': args.columns, 'rows': args.rows, 'syntheticOnly': True,
                'physicalDesktopUsed': False, 'liveProviderWrites': 0, 'calendarWrites': 0,
                'fixtureSends': 0, 'selectedEvent': HERO,
                'allSevenDaysVisible': True, 'enterOpensSameJoinEvent': True,
                'marks': tape['marks'], 'allOwnedPtyAndCliChildrenReaped': True, **finish,
            })
        finally:
            rec.close()
    print(f'Captured genuine {args.columns}×{args.rows} week; same selected event opens with Enter')


if __name__ == '__main__':
    main()
