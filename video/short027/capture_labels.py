#!/usr/bin/env python3
"""One complete staged-label task in a fresh fictional owned PTY.

The actual two-message Apply writes only the mock provider. No production
configuration, desktop, account or email send is accessed. Run under the
coordinator's existing live cooperative HOST_TOKEN reservation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
from capture import (ROOT, reservation, recorder, ready, mark, click, save_tape,
                     make, options, seed, WORK, MEETING_ID, BOOKING_ID, REPORT_ID)
from build_info import read_build_info
from terminal_integration import Client, require


def read_messages(binary, directory, extra, ids):
    with Client(binary, directory, extra=extra) as client:
        return {key: client.request('mail.read', WORK, messageId=key, cacheOnly=True)
                for key in ids}


def reader_labels(rec):
    column, row = rec.locate('Labels:')
    return rec.line(row)[column:]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--expected-sha256', required=True)
    p.add_argument('--out', type=Path, default=ROOT/'video/cache/short027')
    args = p.parse_args()
    reservation()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'capture executable changed')
    info = read_build_info(binary)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ids = (MEETING_ID, BOOKING_ID)
    with tempfile.TemporaryDirectory(prefix='omagma-short027-labels-') as temporary:
        directory = Path(temporary)
        source, config, _ = make(directory)
        extra = options(source, config)
        seed(binary, directory, source, config)
        before = read_messages(binary, directory, extra, (*ids, REPORT_ID))
        rec = recorder(binary, directory, source, config, 'labels')
        try:
            ready(rec)
            require('Projects' in reader_labels(rec), 'initial reader lacks original label')
            mark(rec, 'labels-context', account=WORK, messageId=MEETING_ID)
            rec.press('  m', 'labels:select-two-and-open', show=False)
            rec.wait(lambda: '[Apply 0]' in rec.text() and '[-]' in rec.text()
                     and '[x]' in rec.text() and 'Messages: 2' in rec.text())
            mark(rec, 'labels-initial', account=WORK, messageIds=ids, changes=0)
            rec.press(' ', 'labels:stage-remove-projects')
            rec.wait(lambda: '[Apply 1]' in rec.text())
            mark(rec, 'labels-stage-one', changes=1, removeLabels=['Projects'])
            rec.press('j', 'labels:choose-travel')
            rec.press(' ', 'labels:stage-add-travel')
            rec.wait(lambda: '[Apply 2]' in rec.text())
            staged = read_messages(binary, directory, extra, ids)
            require(all(staged[key]['labels'] == before[key]['labels'] for key in ids),
                    'staging changed provider labels before Apply')
            mark(rec, 'labels-staged', changes=2, removeLabels=['Projects'],
                 addLabels=['Travel'], messageIds=ids)
            # Separate reviewed activation invokes the real native Apply control.
            click(rec, '[Apply 2]', 'labels:apply')
            rec.wait(lambda: 'Labels · staged changes' not in rec.text()
                     and 'Mail action: 2 applied, 0 restored' in rec.text())
            mark(rec, 'labels-applied', appliedMessages=2, restoredMessages=0)
            after = read_messages(binary, directory, extra, (*ids, REPORT_ID))
            for key in ids:
                expected = (set(before[key]['labels']) - {'Label_projects'}) | {'Label_travel'}
                require(set(after[key]['labels']) == expected,
                        'Apply changed another label or missed a pinned target')
                require(after[key]['bodyText'] == before[key]['bodyText']
                        and after[key]['unread'] == before[key]['unread'],
                        'Apply changed message content or read status')
            require(after[REPORT_ID] == before[REPORT_ID],
                    'Apply touched the unselected report message')
            rec.press('gg', 'labels:inspect-first-result', show=False)
            rec.wait(lambda: 'I · Respond' in rec.text()
                     and 'Travel' in reader_labels(rec)
                     and 'Projects' not in reader_labels(rec))
            mark(rec, 'labels-result', account=WORK, messageId=MEETING_ID,
                 readerLabels=reader_labels(rec))
            # Inspect the second pinned message too; the same camera shows
            # unchanged row positioning and its actual new Travel membership.
            rec.press('j', 'labels:inspect-second-result', show=False)
            rec.wait(lambda: 'Lisbon is calling.' in rec.text()
                     and 'Travel' in reader_labels(rec)
                     and 'Projects' not in reader_labels(rec))
            mark(rec, 'labels-result-second', account=WORK, messageId=BOOKING_ID,
                 readerLabels=reader_labels(rec))
            cleanup = rec.finish(client_extra=extra)
            save_tape(rec, out, info)
        finally:
            rec.close()
    receipt = {'binarySha256': digest, 'buildInfo': info, 'synthetic': True,
               'sameDialogAndCamera': True, 'account': WORK, 'messageIds': ids,
               'initial': {key: before[key]['labels'] for key in ids},
               'final': {key: after[key]['labels'] for key in ids},
               'stagingWasLocal': True, 'twoMessagesApplied': True,
               'unselectedMessageUnchanged': True, 'liveProviderWrites': 0,
               'fixtureOnlyLabelApply': True, 'fixtureSends': 0,
               'allChildrenReaped': True, 'cleanup': cleanup}
    (out/'labels-capture-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    print('Captured same-dialog initial → two staged label changes → actual Apply → verified reader results; zero sends.')


if __name__ == '__main__':
    main()
