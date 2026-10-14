#!/usr/bin/env python3
"""Capture the real Calendar event Join card and profile result in a compact PTY.

Design review is the same pre-existing fictional event as the Calendar chapter.
The two story states are drawn by the frozen native TUI at identical dimensions.
Original short029 captures are never rewritten.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
import tempfile
from pathlib import Path

from capture_calendar import (
    ROOT, KNOWN, WORK, INVITE, HERO, HERO_URL, StoryFixture, Recorder, Client,
    read_build_info, require, reserve, stable, calendar_wait, native_join_proof,
    provider_state, save, write_json,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'video/cache/short029/revision-02/join-compact')
    parser.add_argument('--columns', type=int, default=120)
    parser.add_argument('--rows', type=int, default=26)
    args = parser.parse_args()
    reserve()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'compact Join capture binary changed')
    info = {'sha256': digest, **read_build_info(binary)}
    out = args.out.resolve()
    require(out != (ROOT / 'video/cache/short029/join-compact').resolve(), 'revision captures must preserve the original compact Join tape')
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omagma-film029-join-compact-') as temporary:
        directory = Path(temporary)
        fixture = StoryFixture(directory)
        fixture.seed(binary)
        with Client(binary, directory, extra=fixture.options()) as client:
            require(provider_state(client, WORK)['writes'] == 0, 'synthetic preparation unexpectedly wrote Calendar')
        rec = Recorder(binary, directory, 'join-compact', columns=args.columns, rows=args.rows,
                       extra=(*fixture.options(), '--account', WORK, '--ui-file', str(fixture.preferences)))
        try:
            rec.wait(lambda: 'Up to date' in rec.text() and INVITE in rec.text())
            rec.gap(.3)
            rec.press('C', 'join:calendar', show=False)
            calendar_wait(rec)
            rec.press('/Design\r', 'join:find-saved-event', show=False)
            rec.wait(lambda: 'Filter: Design' in rec.text() and HERO in rec.text())
            rec.press('\r', 'join:open-saved-event', show=False)
            rec.wait(lambda: 'Calendar · Event' in rec.text() and HERO in rec.text()
                     and '[o Join]' in rec.text() and '' in rec.text())
            stable(rec, 'card')
            lines = rec.screen.lines()
            top = next(y for y, line in enumerate(lines) if '╭' in line and '╮' in line)
            bottom = next(y for y in range(top + 1, len(lines)) if '╰' in lines[y] and '╯' in lines[y])
            left, right = lines[top].index('╭'), lines[top].rindex('╮')
            rec.press('o', 'join:open-profile')
            rec.wait(lambda: 'Join target validated' in rec.text() and 'Profile 1' in rec.text())
            stable(rec, 'profile')
            require(HERO in rec.text() and '' in rec.text(), 'Join result lost the event card')
            finish = rec.finish(expected_sends=0, client_extra=fixture.options())
            with Client(binary, directory, extra=fixture.options()) as client:
                require(provider_state(client, WORK)['writes'] == 0, 'browsing/Join changed Calendar')
            proof = native_join_proof(binary, directory, fixture, HERO_URL)
            tape = rec.tape(info)
            save(out / 'join-compact.json', tape, known=KNOWN)
            # Shared framing contains the native card and native bottom status.
            # The rasterizer may refine this camera while retaining both states.
            rois = {'full': [0, 0, 1, 1], 'focus': [0, 0, 1, 1],
                    'card': [left / args.columns, top / args.rows, (right - left + 1) / args.columns, (bottom - top + 1) / args.rows],
                    'result': [0, (args.rows - 2) / args.rows, 1, 2 / args.rows]}
            receipt = {
                'schema': 'omagma.video.capture.v1', 'captureRevision': '02', 'binary': info,
                'columns': args.columns, 'rows': args.rows, 'syntheticOnly': True,
                'liveProviderWrites': 0, 'physicalDesktopUsed': False,
                'fixtureSends': 0, 'calendarWrites': 0, 'joinEvent': HERO, 'joinUrl': HERO_URL,
                'preparation': 'Same pre-existing Design review fixture as the Calendar chapter; no RSVP preparation or Calendar mutation.',
                'actions': [m for m in tape['marks'] if 'keys' in m],
                'marks': [m for m in tape['marks'] if m.get('stable')],
                'nativeJoinProof': proof, 'allOwnedPtyAndCliChildrenReaped': True, **finish,
                'assets': {key: {'tape': 'join-compact.json', 'mark': mark, 'rois': rois,
                                 'provenance': 'Actual native PTY cells; fictional provider; completed synchronized frame'}
                           for key, mark in [('join.card', 'card'), ('join.profile', 'profile')]},
            }
            write_json(out / 'capture-manifest.json', receipt)
            print(f'Captured genuine compact Join card + profile at {args.columns}x{args.rows}', flush=True)
        finally:
            if sys.exc_info()[0]:
                print(rec.text(), file=sys.stderr)
                save(out / 'join-compact-failed.json', rec.tape(info), known=KNOWN)
            rec.close()


if __name__ == '__main__':
    main()
