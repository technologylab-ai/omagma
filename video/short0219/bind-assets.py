#!/usr/bin/env python3
"""Bind Opus's named cameras/spotlights to exact captured cells and DOM rects.

No application, browser, image or tape is changed. Camera rectangles include
context; rois with the same name may be tighter spotlight rectangles. Originals
and a complete anchor/geometry receipt are preserved before the manifest write.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def union(*rectangles):
    rectangles = [r for r in rectangles if r is not None]
    require(bool(rectangles), "empty anchor union")
    x = min(r[0] for r in rectangles)
    y = min(r[1] for r in rectangles)
    return [x, y, max(r[0] + r[2] for r in rectangles) - x,
            max(r[1] + r[3] for r in rectangles) - y]


class Frame:
    def __init__(self, tape, index):
        self.columns, self.rows = tape["columns"], tape["rows"]
        self.grid = [[" "] * self.columns for _ in range(self.rows)]
        self.styles = [[None] * self.columns for _ in range(self.rows)]
        current = None
        for frame in tape["frames"][:index + 1]:
            current = frame["rows"] if current is None else [new if new is not None else old
                       for new, old in zip(frame["rows"], current)]
        require(current is not None, "missing captured frame")
        for y, row in enumerate(current):
            for x, text, style, width in row:
                if len(text) == width:
                    for offset, char in enumerate(text):
                        self.grid[y][x + offset] = char
                else:
                    self.grid[y][x] = text
                    for offset in range(1, width):
                        self.grid[y][x + offset] = ""
                for offset in range(width):
                    self.styles[y][x + offset] = tape["styles"][style]
        self.cursor = tape["frames"][index].get("cursor")
        self.anchors = {}
        self.exceptions = []

    def text(self, y, left=0, right=None):
        return "".join(self.grid[y][left:right])

    def find(self, literal, *, left=0, right=None, required=True):
        right = self.columns if right is None else right
        for y in range(self.rows):
            for x in range(left, right):
                if not "".join(self.grid[y][x:right]).startswith(literal):
                    continue
                end, emitted = x, ""
                while end < right and len(emitted) < len(literal):
                    emitted += self.grid[y][end]
                    end += 1
                while end < right and self.grid[y][end] == "":
                    end += 1
                result = [x, y, end - x, 1]
                self.anchors[literal] = result
                return result
        require(not required, "required captured anchor absent: " + literal)
        return None

    def pane(self, anchor):
        x, y = anchor[:2]
        choices = []
        for top in range(y + 1):
            for left in range(x + 1):
                if self.grid[top][left] not in ("╭", "┌"):
                    continue
                right = next((r for r in range(left + 1, self.columns)
                              if self.grid[top][r] in ("╮", "┐")), None)
                bottom = next((b for b in range(top + 1, self.rows)
                               if self.grid[b][left] in ("╰", "└")), None)
                if (right is not None and bottom is not None and right >= x and bottom >= y
                        and self.grid[bottom][right] in ("╯", "┘")):
                    # Occluded background panels can retain all four corners.
                    # Require the actual uninterrupted vertical borders too.
                    if all(self.grid[row][left] == "│" and self.grid[row][right] == "│"
                           for row in range(top + 1, bottom)):
                        choices.append([left, top, right - left + 1, bottom - top + 1])
        require(bool(choices), "captured pane corners absent around anchor")
        return min(choices, key=lambda r: r[2] * r[3])

    def clamp(self, rect):
        x, y, width, height = rect
        width, height = min(width, self.columns), min(height, self.rows)
        return [max(0, min(x, self.columns - width)), max(0, min(y, self.rows - height)), width, height]

    def camera(self, content, *, width=90, height=20, x=None, y=None):
        actual_width, actual_height = max(width, content[2]), max(height, content[3])
        if actual_width > width or actual_height > height:
            self.exceptions.append({"intentCells": [width, height],
                                    "requiredToIncludeActualAnchors": content,
                                    "actualCells": [actual_width, actual_height]})
        left = content[0] + (content[2] - actual_width) / 2 if x is None else x
        top = content[1] + (content[3] - actual_height) / 2 if y is None else y
        result = self.clamp([math.floor(left), math.floor(top), actual_width, actual_height])
        require(result[0] <= content[0] and result[1] <= content[1]
                and result[0] + result[2] >= content[0] + content[2]
                and result[1] + result[3] >= content[1] + content[3], "camera clips its required anchors")
        return result

    def normalized(self, rect):
        x, y, width, height = rect
        return [x / self.columns, y / self.rows, width / self.columns, height / self.rows]


def padded(frame, rect, amount=1):
    return frame.clamp([rect[0] - amount, rect[1] - amount, rect[2] + 2 * amount, rect[3] + 2 * amount])


def line_content(frame, y, left=0, right=None):
    right = frame.columns if right is None else right
    occupied = [x for x in range(left, right) if frame.grid[y][x].strip() and frame.grid[y][x] not in '│─╭╮╰╯┌┐└┘']
    require(occupied, 'empty spotlight row')
    return [min(occupied), y, max(occupied) - min(occupied) + 1, 1]


def any_anchor(frame, *literals):
    for literal in literals:
        result = frame.find(literal, required=False)
        if result:
            return result
    raise AssertionError('required native anchor absent: ' + repr(literals))


def header(frame):
    candidates = [y for y in range(frame.rows) if frame.grid[y][5] == '│' and any(day in frame.text(y) for day in
                  ('Mon ', 'Tue ', 'Wed ', 'Thu ', 'Fri ', 'Sat ', 'Sun '))]
    require(candidates, 'Calendar day heading missing')
    return min(candidates)


def bindings(frames):
    """Measure actual content first; reuse camera cells across each native shot."""
    cameras, spots = {}, {}
    def assign(key, name, camera, **rois):
        cameras[key] = {name: camera}
        spots[key] = rois
    def clock(f):
        for y in range(f.rows):
            if not re.match(r'^\d{2}:\d{2}[│┤]', f.text(y)):
                continue
            columns = [x for x, glyph in enumerate(f.grid[y]) if glyph == '─' and f.styles[y][x]
                       and int(f.styles[y][x][0][1:3], 16) > 140
                       and int(f.styles[y][x][0][1:3], 16) > int(f.styles[y][x][0][3:5], 16) * 1.3]
            if len(columns) >= 6:
                result = [0, y, 5, 1]
                f.anchors['actual HH:MM current time'] = result
                return result, [min(columns), y, max(columns) - min(columns) + 1, 1]
        raise AssertionError('genuine red native HH:MM line missing')
    week = frames['calendar.week']
    h = header(week)
    design = any_anchor(week, 'Design crit', 'Design cri', 'Design')
    overflow = week.find('+1')
    standup = week.find('Standup')
    now_clock, now_line = clock(week)
    require(standup[1] < now_line[1] < design[1], 'Week current-time line is not between events')
    column = union(standup, design, overflow, now_line)
    column[3] += 1  # Keep the actual event time row beneath the later title.
    bottom = max(now_clock[1] + 2, design[1] + 2)
    week_camera = [0, h, week.columns, bottom - h]
    require(week_camera[3] <= 23, 'Week context exceeds 23 native rows')
    assign('calendar.week', 'week', week_camera, column=column)
    # Gutter through today's column and the adjacent day, using actual cell
    # pitch from the native separators rather than a fabricated weekday grid.
    today_width = now_line[0] + now_line[2] + 15
    require(today_width <= 84, 'today plus neighbor exceeds authored 84 columns')
    today_content = union(column, now_clock, [0, h, today_width, 1])
    cameras['calendar.week']['today'] = week.camera(today_content, width=today_width, height=19, x=0, y=h)
    for key in ('calendar.day', 'calendar.day-classic', 'calendar.day-back'):
        f = frames[key]
        first, second = f.find('Design crit'), f.find('Vendor call')
        require(first[1] == second[1] and second[0] - first[0] >= 8, 'native Day events do not occupy distinct lanes')
        lanes = union(first, second)
        lanes[3] = 2  # Both titles and their exact native time rows.
        now_clock, now_line = clock(f)
        day_content = union(f.find('Recycling day'), f.find('Standup'), lanes, now_clock, now_line)
        top = next(y for y in range(f.rows) if '[q Mail]' in f.text(y) and 'Day' in f.text(y))
        cam = [0, top, f.columns, 23]
        require(cam[1] + cam[3] <= f.rows, 'Day tab/header plus 23 rows exceeds native grid')
        for title in (first, second):
            x, y = title[:2]
            background = f.styles[y][x][1]
            require(background is not None, 'Day lane has no actual native block surface')
            last = y
            while last + 1 < f.rows and f.styles[last + 1][x] and f.styles[last + 1][x][1] == background:
                last += 1
            require(last < cam[1] + cam[3], 'Day camera clips an actual lane duration row')
        rois = {'lanes': lanes} if key == 'calendar.day' else (
               {'allday': f.find('Recycling day')} if key == 'calendar.day-back' else {})
        assign(key, 'day', cam, **rois)
    # Titles, Guests row, and popup measured from the actual suggestion frame.
    f = frames['guest.suggest']
    title, guests = f.find('Title:'), f.find('Guests:')
    popup = union(f.find('Suggestions ·'), f.find('alex@example.test'), f.find('↓/Ctrl+N Choose'))
    content = union(title, guests, popup)
    form_cam = f.camera(content, width=min(96, f.columns), height=min(21, content[1] + content[3] - title[1] + 2), x=0, y=max(0, title[1] - 1))
    require(form_cam[3] <= 21, 'guest form exceeds 21 native rows')
    for key in ('guest.empty', 'guest.typed', 'guest.suggest', 'guest.selected', 'guest.added'):
        if key not in frames:
            continue
        f = frames[key]
        rois = {}
        if key == 'guest.empty':
            row = f.find('Guests:')[1]
            rois['guests'] = union(line_content(f, row), f.find('[Ctrl+Space Browse all]'))
        elif key == 'guest.suggest':
            rois['suggest'] = union(f.find('Suggestions ·'), f.find('Alex Example'), f.find('alex@example.test'))
        elif key == 'guest.selected':
            rois['choice'] = union(f.find('Alex Example'), f.find('alex@example.test'))
        elif key == 'guest.added':
            rois['field'] = union(f.find('Guests:'), f.find('alex@example.test'))
        assign(key, 'form', form_cam, **rois)
    before, done = frames['rsvp.before'], frames['rsvp.done']
    result_top = max(0, min(header(before), header(done), before.rows - 21))
    result = [0, result_top, before.columns, before.rows - result_top]
    require(result[3] <= 22, 'RSVP grid/status context exceeds legibility floor')
    for key in ('rsvp.before', 'rsvp.done'):
        f = frames[key]
        candidates = []
        for y in range(f.rows - 4):
            found = f.find('Studio sync', required=False)
            if 'Studio sync' in f.text(y) and y > header(f):
                x = f.text(y).index('Studio sync')
                candidates.append([x, y, len('Studio sync'), 1])
        require(candidates, 'Studio sync not present inside the grid')
        event_rect = candidates[0]
        event_rect = f.clamp([max(0, event_rect[0] - 2), event_rect[1], event_rect[2] + 2, 1])
        rois = {'event': event_rect} if key == 'rsvp.before' else {}
        if key == 'rsvp.done':
            status = f.find('Accepted · Studio sync')
            rois['status'] = line_content(f, status[1])
        assign(key, 'result', result, **rois)
    review, accept = frames['rsvp.review'], frames['rsvp.accept']
    review_dialog = review.pane(review.find('Your answer now'))
    accept_dialog = accept.pane(accept.find('Your answer now'))
    assign('rsvp.review', 'dialog', review_dialog, choices=union(review.find('Accept · a'), review.find('Maybe · m'), review.find('Decline · x')))
    consequence = any_anchor(accept, 'Accepts this event', 'Accepts ', 'Google emails your answer')
    confirm = any_anchor(accept, '[y Accept')
    consequence_rows = [line_content(accept, y, left=accept_dialog[0] + 1, right=accept_dialog[0] + accept_dialog[2] - 1)
                        for y in range(consequence[1], confirm[1] + 1)]
    assign('rsvp.accept', 'dialog', accept_dialog, confirm=union(*consequence_rows))
    f = frames['ics.mail']
    from_row, subject = any_anchor(f, 'From:', 'From   '), f.find('Your November bill')
    card = union(f.find('payment-due.ics'), any_anchor(f, 'Pay Harbor Utilities bill', 'Calendar event'), any_anchor(f, '[A Add to calendar]', 'A Add to calendar', 'A · Add'))
    body = any_anchor(f, 'EUR 48.20', '48.20')
    reader_content = union(from_row, subject, body, card)
    reader = f.camera(reader_content, width=92, height=20)
    assign('ics.mail', 'reader', reader, card=card)
    review, saved = frames['ics.review'], frames['ics.saved']
    modal = review.pane(review.find('Add to calendar'))
    require(modal[2] <= 92 and modal[3] <= 20, 'ICS modal too large')
    require(saved.pane(saved.find('Add to calendar')) == modal, 'native ICS review/result border boxes changed')
    details_start = review.find('Pay Harbor Utilities bill')[1]
    details_end = any_anchor(review, 'Reminder', 'Popup', 'popup')[1]
    details = union(*(line_content(review, y, left=modal[0] + 1, right=modal[0] + modal[2] - 1)
                      for y in range(details_start, details_end + 1) if review.text(y, modal[0] + 1, modal[0] + modal[2] - 1).strip()))
    assign('ics.review', 'modal', modal, details=details)
    assign('ics.saved', 'modal', modal, status=saved.find('Added to your primary calendar.'))
    f = frames['ics.calendar']
    content = union(f.find('Pay Harbor Utilities bill'), f.find('Market visit'), f.find('Lunch with Maya'))
    top = header(f)
    day = [0, top, f.columns, max(18, content[1] + content[3] - top + 1)]
    require(day[3] <= 21, 'ICS populated Day crop exceeds 21 rows')
    assign('ics.calendar', 'day', day, added=f.find('Pay Harbor Utilities bill'))
    f = frames['draft.typing']
    body = union(*(f.find(line, right=f.columns * 3 // 5) for line in ('Hi Maya,', 'Shall we try the new bakery on Saturday?', 'I can book a table for ten.', 'Robin')))
    compose_content = union(f.find('To:'), f.find('Subject: Saturday plans'), body)
    compose = [0, 1, f.columns, 19]
    require(contained(f.normalized(compose_content), f.normalized(compose)), 'compose camera clips actual content')
    assign('draft.typing', 'compose', compose, body=body)
    assign('draft.restored', 'compose', compose, body=body)
    f = frames['draft.review']
    prompt = union(f.find('Discard local draft'), f.find('Discard this draft?'),
                   f.find('Ctrl+X again discards · Esc keeps the draft'), f.find('[Ctrl+X Discard]'), f.find('[Esc Cancel]'))
    review_cam = [0, 1, f.columns, 19]
    assign('draft.review', 'review', review_cam, prompt=prompt)
    f = frames['draft.discarded']
    status = f.find('Draft discarded · Ctrl+Z Undo')
    mail = [0, 3, f.columns, 21]
    assign('draft.discarded', 'mail', mail, status=status)
    return cameras, spots


def valid(rect):
    return (isinstance(rect, list) and len(rect) == 4 and all(isinstance(v, (int, float)) and math.isfinite(v) for v in rect)
            and min(rect) >= 0 and rect[2] > 0 and rect[3] > 0
            and rect[0] + rect[2] <= 1.000001 and rect[1] + rect[3] <= 1.000001)


def contained(inner, outer):
    return (inner[0] >= outer[0] - 1e-8 and inner[1] >= outer[1] - 1e-8
            and inner[0] + inner[2] <= outer[0] + outer[2] + 1e-8
            and inner[1] + inner[3] <= outer[1] + outer[3] + 1e-8)


def validate_contract(manifest, plan, frames, *, floor=26):
    """Independent checks derive requirements from the immutable actual Opus plan."""
    assets, contract = manifest['assets'], plan['assetRequirements']
    require(all(key in assets for key in contract['required']), 'missing required film assets')
    checked = {}
    for key, needed in contract['namedRois'].items():
        if key not in assets and key in contract.get('optional', []):
            continue
        entry = assets[key]
        require(re.fullmatch(r'[a-z0-9][a-z0-9.-]*', key) is not None, 'invalid asset name')
        require(key in frames, 'native tape/frame missing for required asset ' + key)
        f = frames[key]
        require(entry['columns'] == f.columns and entry['rows'] == f.rows, 'native grid metadata drift')
        for group in ('cameraRois', 'rois'):
            for name in needed[group]:
                require(name in entry.get(group, {}) and valid(entry[group][name]), 'missing/invalid binding ' + key + '.' + group + '.' + name)
        cameras = entry['cameraRois']
        for name, rect in cameras.items():
            require(valid(rect), 'invalid camera geometry ' + key + '.' + name)
            cells = [rect[0] * f.columns, rect[1] * f.rows, rect[2] * f.columns, rect[3] * f.rows]
            x, y, width, height = cells
            if key == 'calendar.week':
                cap = (104, 23) if name == 'week' else (84, 19)
                require(width <= cap[0] + 1e-6 and height <= cap[1] + 1e-6, 'Week/today camera exceeds authored cell cap')
            elif key.startswith('calendar.day'):
                require(abs(width - 104) < 1e-6 and abs(height - 23) < 1e-6, 'Day camera must be exactly 104 by 23 cells')
            elif key.startswith('guest.'):
                require(width <= 96 + 1e-6 and height <= 21 + 1e-6, 'guest camera exceeds authored cell cap')
            elif key.startswith('rsvp.'):
                if name == 'result':
                    require(width <= 98 + 1e-6 and height <= 21.8 + 1e-6, 'RSVP result camera exceeds authored cell cap')
                else:
                    require(all(abs(a - b) < 1e-6 for a, b in zip(cells, f.pane(f.find('Your answer now')))), 'RSVP dialog camera is not its exact actual border box')
            elif key in ('ics.review', 'ics.saved'):
                require(all(abs(a - b) < 1e-6 for a, b in zip(cells, f.pane(f.find('Add to calendar')))), 'ICS camera is not exact actual modal border box')
            elif key == 'ics.mail':
                require(width <= 92 + 1e-6 and height <= 20 + 1e-6, 'ICS reader exceeds authored cell cap')
            elif key == 'ics.calendar':
                require(abs(width - f.columns) < 1e-6 and height <= 21 + 1e-6, 'ICS Day camera is not full-width or exceeds row cap')
            elif key.startswith('draft.'):
                require(abs(width - 96) < 1e-6 and height <= (21 if name == 'mail' else 20) + 1e-6 and y >= 1 - 1e-6, 'draft camera must be full96 columns, below header, within authored row cap')
                if name == 'compose':
                    require(y + height <= f.rows - 4 + 1e-6, 'draft compose camera includes footer/status rows')
        for name, rect in entry.get('rois', {}).items():
            require(valid(rect), 'invalid spotlight ' + key + '.' + name)
            require(any(contained(rect, cam) for cam in cameras.values()), 'spotlight outside camera ' + key + '.' + name)
        box = plan['layout']['frameBox']['foot' if key.startswith('draft.') else 'default']
        inner_width, inner_height = box[2] - 28, box[3] - 28
        font = entry['width'] / f.columns / .6
        checked[key] = {}
        for name, rect in cameras.items():
            require(valid(rect), 'invalid camera ' + key + '.' + name)
            size = font * min(inner_width / (rect[2] * entry['width']), inner_height / (rect[3] * entry['height']), 1, 34 / font)
            require(size >= floor - .001, 'native camera below 26px floor: ' + key + '.' + name + ' = ' + str(size))
            checked[key][name] = size
    for group in contract['identicalCameraCells']:
        present = [key for key in group if key in assets]
        baseline = assets[present[0]]
        for key in present[1:]:
            entry = assets[key]
            require((entry['columns'], entry['rows'], entry['width'], entry['height']) ==
                    (baseline['columns'], baseline['rows'], baseline['width'], baseline['height']), 'mixed grids in shot ' + key)
            require(entry['cameraRois'] == baseline['cameraRois'], 'identical camera cells changed in shot ' + key)
    original, restored = frames['draft.typing'], frames['draft.restored']
    body = assets['draft.typing']['rois']['body']
    x, y, width, height = [round(v * n) for v, n in zip(body, (original.columns, original.rows, original.columns, original.rows))]
    require(all(original.grid[row][x:x + width] == restored.grid[row][x:x + width] for row in range(y, y + height)), 'restored native body differs cell-for-cell')
    return checked


def main():
    import re
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='revision-01')
    parser.add_argument('--plan', type=Path, default=ROOT / 'video/short0219/film-plan.json')
    parser.add_argument('--source-manifest', type=Path)
    parser.add_argument('--attempt', default='01')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    require(re.fullmatch(r'revision-\d{2}', args.revision) is not None, 'owned revision required')
    require(args.attempt.isdigit(), 'numeric binding attempt required')
    root = ROOT / 'video/cache/short0219' / args.revision
    path = root / 'assets-manifest.json'
    original = (args.source_manifest or path).read_bytes()
    manifest, plan = json.loads(original), json.loads(args.plan.read_text())
    require(manifest['schema'] == 'omagma.video.assets.v1', 'wrong manifest schema')
    frames, tapes = {}, {}
    receipt = {'schema': 'omagma.video.binding.v1', 'inputManifestSha256': hashlib.sha256(original).hexdigest(),
               'planSha256': digest(args.plan), 'assets': {}, 'unchangedImageHashes': {}}
    for key, entry in manifest['assets'].items():
        file = ROOT / entry['file'].lstrip('/') if entry['file'].startswith('/') else root / entry['file']
        require(digest(file) == entry['sha256'], 'raster bytes changed: ' + key)
        receipt['unchangedImageHashes'][key] = entry['sha256']
        if 'tape' not in entry:
            continue
        tape_path = (root / entry['tape']).resolve()
        require(tape_path.is_relative_to(root.resolve()) and tape_path.suffix == '.json', 'unowned tape path')
        require(digest(tape_path) == entry['tapeSha256'], 'tape bytes changed: ' + key)
        tape = tapes.setdefault(entry['tape'], json.loads(tape_path.read_text()))
        require(isinstance(entry['frame'], int) and 0 <= entry['frame'] < len(tape['frames']), 'invalid completed frame ' + key)
        marks = [m for m in tape['marks'] if m['name'] == entry['mark']]
        require(len(marks) == 1 and marks[0]['frame'] == entry['frame'], 'asset mark/frame binding mismatch ' + key)
        frames[key] = Frame(tape, entry['frame'])
    cameras, spots = bindings(frames)
    for key, f in frames.items():
        entry = manifest['assets'][key]
        entry['cameraRois'] = {name: f.normalized(rect) for name, rect in cameras[key].items()}
        entry['rois'] = {name: f.normalized(rect) for name, rect in spots[key].items()}
        receipt['assets'][key] = {'anchors': f.anchors, 'cellCameras': cameras[key], 'cellRois': spots[key]}
    receipt['cameraApparentFontPx'] = validate_contract(manifest, plan, frames)
    receipt['assetCount'] = len(manifest['assets'])
    encoded = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
    receipt['outputManifestSha256'] = hashlib.sha256(encoded).hexdigest()
    if not args.dry_run:
        suffix = '' if args.attempt == '01' else '-' + args.attempt
        backup = root / ('assets-manifest.before-binding' + suffix + '.json')
        require(not backup.exists(), 'preserve previous binding attempt')
        backup.write_bytes(path.read_bytes())
        receipt_path = root / 'asset-binding-receipt.json'
        if receipt_path.exists():
            old_receipt = root / ('asset-binding-receipt.before' + suffix + '.json')
            require(not old_receipt.exists(), 'preserve previous binding receipt')
            old_receipt.write_bytes(receipt_path.read_bytes())
        path.write_bytes(encoded)
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print('PASS ' + ('dry-run ' if args.dry_run else '') + 'actual v0.2.19 bindings: ' + str(len(frames)) + ' native assets; every required camera and spotlight validated')


if __name__ == '__main__':
    main()
