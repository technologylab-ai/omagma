#!/usr/bin/env python3
"""Align film to measured capture ROIs without rewriting native geometry."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'video/cache/short029'


def union(*rects):
    x = min(r[0] for r in rects)
    y = min(r[1] for r in rects)
    return [x, y, max(r[0] + r[2] for r in rects) - x,
            max(r[1] + r[3] for r in rects) - y]


def main():
    subprocess.run(['node', str(ROOT / 'video/short029/measure-rois.mjs')], check=True)
    manifest_path = CACHE / 'assets-manifest.json'
    timeline_path = ROOT / 'video/short029/timeline.json'
    manifest = json.loads(manifest_path.read_text())
    plan = json.loads(timeline_path.read_text())
    assets = manifest['assets']
    # Revision01's command-typing overrides do not belong to the directed camera and action sequences.
    manifest.pop('sequences', None)
    for key, meta in assets.items():
        if key == 'logo':
            continue
        rois = meta.setdefault('rois', {})
        rois.setdefault('focus', [0, 0, 1, 1])
        # Only measured geometry can create an alias; never overwrite captures.
        for canonical, old in [('calendar_entry', 'calendar'),
                               ('followup_entry', 'followups')]:
            if canonical not in rois and old in rois:
                rois[canonical] = list(rois[old])
        if 'new_entries' not in rois and all(
                r in rois for r in ('calendar_entry', 'followup_entry')):
            rois['new_entries'] = union(rois['calendar_entry'], rois['followup_entry'])
        if key.startswith('join.') and 'overview' not in rois and 'result' in rois:
            rois['overview'] = union(rois.get('card', rois['focus']), rois['result'])

    # A focus-only change uses the same measured modal crop for both frames.
    # Preserve the source's generic focus entry and add an explicit shared alias.
    review = assets.get('rsvp.review', {})
    if 'focus' in review.get('rois', {}):
        for key in ('rsvp.review', 'rsvp.review_opened', 'rsvp.accept_focus'):
            meta = assets.get(key)
            if meta and (meta['width'], meta['height']) == (review['width'], review['height']):
                meta['rois'].setdefault('review', list(review['rois']['focus']))

    expected = 0
    for part in plan['parts']:
        if part['frameIn'] != expected or part['frameOut'] <= expected:
            raise ValueError('Timeline gap or overlap at ' + part['id'])
        expected = part['frameOut']
        if part['id'] == 'rsvp-review' and 'rsvp.review_opened' in assets:
            part['sequence'][0]['asset'] = 'rsvp.review_opened'
        keys = [part.get('asset')] + [s['asset'] for s in part.get('sequence', [])]
        for key in filter(None, keys):
            if key not in assets:
                raise ValueError('Missing revision03 capture: ' + key)
            rois = assets[key].get('rois', {})
            needed = [part['camera']['from'], part['camera']['to'], part.get('focus')]
            needed.extend(s['roi'] for s in part.get('focusSteps', []))
            for name in filter(None, needed):
                if name != 'full' and name not in rois:
                    raise ValueError('Missing measured ROI: ' + key + '.' + name)
    if expected != 2527 or plan['frameCount'] != 2527:
        raise ValueError('Film must retain exactly 2527 frames')
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    timeline_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
    print('Film aligned: measured ROIs preserved; 2527 frames; directed camera and action sequences')


if __name__ == '__main__':
    main()
