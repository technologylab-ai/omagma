#!/usr/bin/env python3
"""Extract untouched and typed-prefix native palette states from a genuine tape.

The original main take already captured every letter of `label` through real
owned-PTY input. This helper preserves its terminal frames/styles verbatim and
adds observation marks; it never draws or edits cells and runs no app/provider.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
from capture import ROOT, KNOWN
from tape import save
from terminal_integration import require
PREFIXES = ('', 'l', 'la', 'lab', 'labe', 'label')


def rows_through(tape):
    rows = [[] for _ in range(tape['rows'])]
    for index, frame in enumerate(tape['frames']):
        for y, row in enumerate(frame['rows']):
            if row is not None:
                rows[y] = row
        yield index, frame, copy.deepcopy(rows)


def cell_line(runs, width):
    cells = [' '] * width
    for x, text, _style, _cells in runs:
        # Current palette uses ordinary ASCII text. Preserve all native cell
        # contents separately; this reconstruction is used only to locate the
        # unambiguous literal query prefix in the native Filter row.
        for offset, char in enumerate(text):
            if x + offset < width:
                cells[x + offset] = char
    return ''.join(cells)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, default=ROOT/'video/cache/short027/main.json')
    p.add_argument('--out', type=Path, default=ROOT/'video/cache/short027')
    p.add_argument('--expected-sha256', required=True)
    args = p.parse_args()
    source_path = args.source.resolve()
    raw = source_path.read_bytes()
    source = json.loads(raw)
    receipt_path = source_path.parent/'capture-receipt.json'
    provenance = json.loads(receipt_path.read_text())
    require(provenance['binarySha256'] == args.expected_sha256,
            'source executable provenance changed')
    require(provenance['fixtureSends'] == 0 and provenance['liveProviderWrites'] == 0,
            'source was not a zero-send isolated synthetic capture')
    open_mark = next(mark for mark in source['marks'] if mark['name'] == 'palette:open')
    query_mark = next(mark for mark in source['marks'] if mark['name'] == 'palette:query')
    done_mark = next(mark for mark in source['marks'] if mark['name'] == 'palette:query:done')
    require(open_mark['keys'] == '\x10' and query_mark['typed'] == 'label',
            'source did not actually open Ctrl+P and type the intended query')
    states = {}
    for index, frame, rows in rows_through(source):
        if not open_mark['frame'] <= index <= done_mark['frame']:
            continue
        lines = [cell_line(row, source['columns']) for row in rows]
        if not any('─ Actions ' in line for line in lines):
            continue
        for row, line in enumerate(lines):
            if 'Filter: ' not in line or '▏' not in line:
                continue
            prefix = line.split('Filter: ', 1)[1].split('▏', 1)[0]
            if prefix in PREFIXES and prefix not in states:
                states[prefix] = {'frame': index, 't': frame['t'],
                                  'filterRow': row, 'filterColumn': line.index('Filter: ')}
    require(tuple(states) == PREFIXES, 'source lacks an ordered native prefix state')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tape = copy.deepcopy(source)
    tape['tape'] = 'palette'
    last_frame = states['label']['frame']
    tape['frames'] = source['frames'][:last_frame + 1]
    tape['marks'] = [mark for mark in source['marks']
                     if mark['frame'] <= last_frame and mark['t'] <= done_mark['t']]
    for prefix, state in states.items():
        name = 'palette-initial' if not prefix else 'palette-' + prefix
        tape['marks'].append({'name': name, **state, 'typedPrefix': prefix,
                              'sourceInputMark': 'palette:query' if prefix else 'palette:open',
                              'timing': 'observed native frame; original input marks retained'})
    tape['marks'].sort(key=lambda mark: mark['t'])
    tape['extraction'] = {'sourceTape': 'main', 'sourceSha256': hashlib.sha256(raw).hexdigest(),
                          'cellChanges': 0, 'nativeFramesVerbatim': True,
                          'actualInput': 'Ctrl+P, then l/a/b/e/l in owned PTY'}
    save(out/'palette.json', tape, known=KNOWN)
    receipt = {'source': source_path.name, 'sourceSha256': hashlib.sha256(raw).hexdigest(),
               'binarySha256': provenance['binarySha256'], 'buildInfo': provenance['buildInfo'],
               'reusedExistingGenuineFrames': True, 'cellChanges': 0,
               'states': states, 'actualInput': query_mark, 'openInput': open_mark,
               'synthetic': True, 'fixtureSends': 0, 'liveProviderWrites': 0,
               'noNativeChildrenStarted': True}
    (out/'palette-capture-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    print('Reused untouched palette and all five genuine typed-prefix frames; no new native capture.')


if __name__ == '__main__':
    main()
