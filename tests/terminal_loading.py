#!/usr/bin/env python3
"""Actual partial-metadata/body arrivals and animated loading in owned PTYs."""
import argparse
from pathlib import Path
import tempfile
import time
import json

from terminal_integration import ACCOUNTS, require
from terminal_scroll_progress import fixture, seed, start, settled, contains, tail
from terminal_html import screen_capture


def held(source, phase, completed):
    name = f'loading-{phase}'
    hold, entered = source.root / f'{name}.hold', source.root / f'{name}.entered'
    hold.write_text('Fictional loading hold\n')
    entered.unlink(missing_ok=True)
    source.data[ACCOUNTS[0]]['baseline']['sync'] = {}
    # ProviderFixture.stage supplies its own sync snapshot; add controls to
    # the actual staged source rather than a reference fixture.
    source.stage(ACCOUNTS[0], 'baseline')
    import json
    p = source.path(ACCOUNTS[0]); data = json.loads(p.read_text())
    data['sync']['fixtureProgress'] = {'phase': phase, 'completed': completed,
        'fixtureHold': hold.name, 'fixtureEntered': entered.name}
    p.write_text(json.dumps(data))
    return hold, entered


def wait_marker(t, path):
    t.until(lambda:path.is_file())


def frames(t):
    seen = set()
    deadline = time.monotonic() + .8
    while time.monotonic() < deadline:
        t.pump(.04)
        text = t.text()
        for frame in ('▱▱▱','▰▱▱','▱▰▱','▱▱▰'):
            if frame in text: seen.add(frame)
    return seen


def run(binary, directory, capture_dir=None):
    source = fixture(directory)
    seed(binary, directory, source, 40)
    t = start(binary, directory, source, 40)
    hold = body_hold = None
    try:
        settled(t,96)
        tail(t,65); t.send(b'j'); t.until(lambda:contains(t,64)); tail(t,57)
        hold, entered = held(source,'metadata',1)
        t.send(b'j')
        wait_marker(t,entered)
        t.until(lambda:'metadata 1/32' in t.text())
        require(contains(t,57),'loading replaced the usable cached reader')
        t.until(lambda:'Scroll fixture personal 056' in t.text())
        seen = frames(t)
        if capture_dir:
            capture_dir.mkdir(parents=True,exist_ok=True)
            (capture_dir/'13-loading-metadata.json').write_text(json.dumps(screen_capture(t)))
        require(len(seen)>=2,'unavailable metadata placeholders did not animate')
        require('Scroll fixture personal 055' not in t.text(), 'unarrived metadata was fabricated')
        # Switch only the next body request's fictional provider source. The
        # in-flight list keeps its own parsed metadata source.
        body_hold, body_entered = held(source,'bodies',0)
        hold.unlink(missing_ok=True)
        wait_marker(t,body_entered)
        t.until(lambda:'bodies 0/1' in t.text())
        require(not contains(t,56),'unreceived body appeared before the provider completed')
        require(len(frames(t))>=2,'body placeholders did not animate')
        if capture_dir:
            (capture_dir/'14-loading-body.json').write_text(json.dumps(screen_capture(t)))
        body_hold.unlink(missing_ok=True)
        t.until(lambda:contains(t,56))
        t.gap(.3)
        require('bodies 0/1' not in t.text(),'finished body kept its loading fraction')
        t.send(b'lK')
        t.until(lambda:contains(t,57))
        t.finish()
        print('PASS animated loading: actual first metadata row, remaining placeholders, retained cached reader, body wait/completion and backward cache navigation')
    except Exception:
        print(t.text())
        raise
    finally:
        if hold:hold.unlink(missing_ok=True)
        if body_hold:body_hold.unlink(missing_ok=True)
        t.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--capture-dir',type=Path)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-loading-ui-') as tmp:
        run(args.binary.resolve(),Path(tmp),args.capture_dir)


if __name__=='__main__':main()
