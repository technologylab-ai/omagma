#!/usr/bin/env python3
"""Read-only native capture/outcome/binding audit; no browser or application.

Final evidence additionally binds the manifest to the coordinator's independently
verified published executable checksum. Development evidence remains explicit.
"""
from __future__ import annotations
import argparse
import copy
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'video/capture'), str(ROOT / 'tests')]
from tape import privacy_scan, tape_texts
spec = importlib.util.spec_from_file_location('native_bindings', Path(__file__).with_name('bind-assets.py'))
binding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)
require = binding.require


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='revision-01')
    parser.add_argument('--allow-development', action='store_true')
    parser.add_argument('--allow-candidate', action='store_true', help='pre-publication engineering audit only; cannot authorize delivery')
    parser.add_argument('--publication-proof', type=Path, help='separate verified public-download receipt; immutable capture status stays unchanged')
    parser.add_argument('--expected-binary-sha256')
    parser.add_argument('--negative-checks', action='store_true')
    args = parser.parse_args()
    require(re.fullmatch(r'revision-\d{2}', args.revision), 'owned revision required')
    cache = ROOT / 'video/cache/short0219' / args.revision
    path = cache / 'assets-manifest.json'
    manifest = json.loads(path.read_text())
    capture = json.loads((cache / 'capture-manifest.json').read_text())
    plan = json.loads((ROOT / 'video/short0219/film-plan.json').read_text())
    require(not capture.get('failure'), 'failed capture cannot be used')
    require(manifest['captureReceiptSha256'] == digest(cache / 'capture-manifest.json'), 'capture receipt changed after raster')
    require(capture['synthetic'] and capture['liveProviderWrites'] == 0 and capture['userClipboardRead'] is False, 'unsafe capture context')
    require(capture['sourceStatus'] == manifest['sourceStatus'], 'source status drift')
    require(not (args.allow_development and args.allow_candidate), 'development and candidate audits are distinct')
    candidate = capture['sourceStatus'] == 'frozen-release-candidate'
    if candidate:
        require(capture.get('sourceStatusAtCapture') == 'frozen-release-candidate'
                and capture.get('publicationRequiredBeforeDelivery') is True, 'candidate chronology/delivery gate missing')
        seal = capture.get('candidateProof', {})
        require(seal.get('file') == 'frozen-candidate-proof.json', 'unowned candidate seal')
        require(digest(cache / seal['file']) == seal['sha256'], 'immutable frozen artifact receipt changed')
        frozen = json.loads((cache / seal['file']).read_text())
        require(frozen.get('schema') == 'omagma.video.frozen-candidate.v1'
                and frozen['binarySha256'] == capture['binarySha256'] and frozen['jobConclusion'] == 'success'
                and frozen['head'] == seal['head'] and frozen['run'] == seal['run'] and frozen['artifact'] == seal['artifact'],
                'frozen native artifact identity differs from capture')
        require(manifest.get('candidateProof') == seal and manifest.get('publicationRequiredBeforeDelivery') is True,
                'raster lost frozen-candidate chronology or publication gate')
    publication = None
    if args.publication_proof:
        raw = args.publication_proof.read_bytes()
        require(len(raw) <= 256 * 1024, 'public receipt exceeds bound')
        publication = json.loads(raw)
        require(publication.get('schema') == 'omagma.video.publication-proof.v1'
                and publication.get('published') is True and publication.get('releaseTag') == 'v0.2.19'
                and publication.get('binarySha256') == capture['binarySha256']
                and isinstance(publication.get('downloadUrl'), str)
                and publication['downloadUrl'].startswith('https://github.com/technologylab-ai/omagma/releases/download/v0.2.19/'),
                'public native download was not verified identical to captured executable')
        if 'head' in publication and candidate:
            require(publication['head'] == frozen['head'], 'public revision differs from frozen native capture source')
    if args.allow_candidate:
        require(candidate, '--allow-candidate requires immutable frozen native artifact proof')
    elif not args.allow_development:
        require(publication is not None, 'delivery audit BLOCKED: separate public-download publication proof is required')
        require(capture['sourceStatus'] in ('published-v0.2.19', 'frozen-release-candidate')
                and capture['buildInfo']['appVersion'] == '0.2.19', 'final audit refuses development-only captures')
    if args.expected_binary_sha256:
        require(capture['binarySha256'] == args.expected_binary_sha256, 'independently expected executable SHA differs from native capture')
    require(capture['binarySha256'] == manifest['binarySha256'], 'raster executable hash drift')
    require(capture['buildInfo']['zigVersion'] == '0.17.0' and capture['buildInfo']['buildMode'] == 'safe', 'wrong compiler/backend')
    frames, tapes = {}, {}
    known = ('alex@example.test', 'billing@harbor-utilities.example', 'calendar-owner@example.org')
    for key, entry in manifest['assets'].items():
        image_path = ROOT / entry['file'].lstrip('/') if entry['file'].startswith('/') else cache / entry['file']
        require(digest(image_path) == entry['sha256'], 'image bytes changed ' + key)
        if 'tape' not in entry:
            continue
        tape_path = (cache / entry['tape']).resolve()
        require(tape_path.is_relative_to(cache.resolve()), 'unowned tape path')
        require(digest(tape_path) == entry['tapeSha256'], 'tape changed ' + key)
        if entry['tape'] not in tapes:
            tape = json.loads(tape_path.read_text())
            privacy_scan(tape_texts(tape), known=known)
            require(tape['binary'] == capture['buildInfo'], 'tape backend drift ' + key)
            tapes[entry['tape']] = tape
        tape = tapes[entry['tape']]
        mark = [m for m in tape['marks'] if m['name'] == key]
        require(len(mark) == 1 and mark[0]['frame'] == entry['frame'] == capture['assets'][key]['frame'], 'wrong exact state/frame binding ' + key)
        frames[key] = binding.Frame(tape, entry['frame'])
    sizes = binding.validate_contract(manifest, plan, frames)
    for story in ('calendar', 'guests', 'draft'):
        proof = capture['proofs'][story]
        require(proof['calendarWrites'] == proof['fixtureSends'] == 0, 'read-only outcome drift ' + story)
    calendar = capture['proofs']['calendar']
    require(calendar['looks'] == ['orange_blue', 'classic_pastel', 'orange_blue'] and len(set(calendar['providerCalls'])) == 1,
            'Calendar toggle changed provider calls or did not restore look')
    for name, proof_name in (('calendar.week', 'weekNow'), ('calendar.day', 'dayNow')):
        frame, proof = frames[name], calendar[proof_name]
        now = datetime.fromisoformat(proof['captureUtc'])
        row, columns = proof['row'], proof['nativeLineColumns']
        require(len(columns) >= 6 and all(frame.grid[row][x] == '─' for x in columns), 'genuine free-time horizontal line missing')
        label = frame.text(row)[:5]
        require(label == proof['nativeClockLabel'], 'native clock label drift')
        require(abs(int(label[:2]) * 60 + int(label[3:]) - now.hour * 60 - now.minute) <= 1, 'native clock differs from actual capture time')
        require(manifest['assets'][name]['currentTimeLineRasterProof']['actualRedPixels'] >= 50, 'native red line not visible in actual raster')
    day = frames['calendar.day']
    first, second = day.find('Design crit'), day.find('Vendor call')
    require(first[1] == second[1] and second[0] - first[0] >= 8, 'Day lanes do not occupy distinct native ranges')
    if not args.allow_development:
        proof = calendar['dayNow']
        require(proof['lastColoredBlockRow'] < proof['cameraEndExclusiveRow'], 'final Day camera clips complete block')
    guests = capture['proofs']['guests']
    require(guests['providerCallsBefore'] == guests['providerCallsAfter'], 'typing used a provider')
    suggest, selected, added = (frames['guest.' + key] for key in ('suggest', 'selected', 'added'))
    guest_candidate = suggest.find('alex@example.test')
    x, y = guest_candidate[:2]
    require(suggest.styles[y][x] != selected.styles[y][x], 'recorded Down did not visibly select the guest')
    require(added.find('alex@example.test')[1] == added.find('Guests:')[1], 'guest was not added to Guests field')
    rsvp = capture['proofs']['rsvp']
    request = rsvp['request']
    require(rsvp['calendarWrites'] == 1 and rsvp['fixtureSends'] == 0 and rsvp['beforeConfirmationWrites'] == 0,
            'RSVP count drift')
    require(request['method'] == 'PATCH' and request['eventId'] == 'studio-sync' and request['ifMatch'] == '"film019-studio-sync"', 'RSVP was not version checked')
    require(json.loads(request['body'])['attendees'] == [{'email': 'personal@example.com', 'responseStatus': 'accepted'}], 'wrong RSVP body')
    require(frames['rsvp.done'].find('Accepted · Studio sync') and frames['rsvp.done'].find('Evening walk'), 'RSVP lost native populated result')
    ics = capture['proofs']['ics']
    require(ics['calendarWrites'] == 1 and ics['fixtureSends'] == 0 and len(ics['requests']) == 1 and ics['requests'][0]['method'] == 'POST', 'ICS insertion count drift')
    require('ATTENDEE' not in ics['source'] and 'METHOD:PUBLISH' in ics['source'] and 'TRIGGER:-PT15H' in ics['source'], 'ICS is not the promised personal elapsed reminder')
    require('DTSTART;VALUE=DATE:' + ics['dueDate'].replace('-', '') in ics['source'], 'source ICS date drift')
    require(ics['event']['start'] == {'date': ics['dueDate']} and not ics['event'].get('attendees')
            and ics['event']['reminders'] == {'useDefault': False, 'overrides': [{'method': 'popup', 'minutes': 900}]}, 'saved all-day reminder drift')
    require(frames['ics.review'].find('Reminder  15 hours before'), 'native review omitted popup reminder')
    require(frames['ics.calendar'].find('Market visit') and frames['ics.calendar'].find('Lunch with Maya'), 'ICS result is not populated')
    draft = capture['proofs']['draft']
    require(draft['gmailDraftDeletes'] == draft['gmailProviderLedgerCount'] == draft['mailboxProviderWrites'] == 0,
            'draft workflow touched Gmail/mailbox')
    require([s['count'] for s in draft['lifecycle']] == [1, 0, 1] and draft['restoredDataEqualsOriginal'], 'retained draft lifecycle drift')
    setup = draft['preReviewedSetup']
    require(setup['keys'] == ['Ctrl+S', 'Esc', 'i'] and setup['beforeInitialState']
            and setup['exactMimeBytes'] > 0 and setup['sendConfirmed'] is False
            and setup['recoveryFieldsAfterSetup'] is False and setup['postRestoreKeys'] == [],
            'local validation setup drift or hidden post-restore key')
    for key in ('draft.typing', 'draft.restored'):
        text = '\n'.join(frames[key].text(y) for y in range(frames[key].rows))
        require('MIME:' in text and 'UnfinishedDraft' not in text, 'validated local draft not settled in native frame')
    for tape_name in ('calendar.json', 'guests.json', 'rsvp.json', 'ics.json', 'draft.json'):
        tape = tapes[tape_name]
        assets = [(key, entry) for key, entry in capture['assets'].items() if entry['tape'] == tape_name]
        require([entry['frame'] for _, entry in assets] == sorted(entry['frame'] for _, entry in assets), 'non-chronological genuine state sequence')
    if args.negative_checks:
        def refused(change):
            bad = copy.deepcopy(manifest)
            change(bad)
            try:
                binding.validate_contract(bad, plan, frames)
            except AssertionError:
                return
            raise AssertionError('negative binding corruption escaped detection')
        refused(lambda m: m['assets']['guest.empty']['cameraRois'].clear())
        refused(lambda m: m['assets']['calendar.week']['rois'].update(column=[.99, .99, .01, .01]))
        refused(lambda m: m['assets']['draft.restored'].update(columns=95))
        refused(lambda m: m['assets']['calendar.day-back']['cameraRois'].update(day=[0, 0, 1, 1]))
        refused(lambda m: m['assets']['calendar.week']['cameraRois']['today'].__setitem__(3, 20 / 30))
    font_min = min(size for cameras in sizes.values() for size in cameras.values())
    print('PASS native v0.2.19 capture audit: ' + str(len(frames)) + ' exact states; five outcomes; all plan camera/spot bindings; minimum ' + str(round(font_min, 2)) + 'px' + ('; corruption controls rejected' if args.negative_checks else '')
          + ('; public download matches immutable capture' if publication else '; PUBLICATION PENDING: no delivery' if candidate else ''))


if __name__ == '__main__':
    main()
