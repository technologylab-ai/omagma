#!/usr/bin/env python3
"""Wheel/touchpad routing over loading rows, blank list space and reader controls."""
import argparse
from pathlib import Path
import tempfile

from terminal_integration import require
from terminal_loading import held,wait_marker
from terminal_mouse import report,click
from terminal_scroll_progress import fixture,seed,start,settled,contains,tail


def pending(binary,directory):
    source=fixture(directory);seed(binary,directory,source,40)
    terminal=start(binary,directory,source,40);hold=None
    try:
        settled(terminal,96)
        tail(terminal,65);terminal.send(b'j');terminal.until(lambda:contains(terminal,64));tail(terminal,57)
        hold,entered=held(source,'metadata',1)
        terminal.send(b'j');wait_marker(terminal,entered)
        terminal.until(lambda:'metadata 1/32' in terminal.text() and 'Fetching metadata' in terminal.text())
        target=terminal.screen.locate('Fetching metadata')
        click(terminal,target['column']+1,target['row'])
        terminal.gap(.08)
        require(contains(terminal,57),'clicking an unfinished row selected another message')
        report(terminal,target['column']+1,target['row'],button=64)
        terminal.until(lambda:contains(terminal,60))
        require('metadata 1/32' not in terminal.text(),'opposite wheel did not cancel the pending older window')
        hold.unlink(missing_ok=True)
        terminal.finish()
        print('PASS touchpad/wheel over fetching placeholders: ignored click, scrolls cached mail upward and cancels older fetch')
    except Exception:
        print(terminal.text());raise
    finally:
        if hold:hold.unlink(missing_ok=True)
        terminal.close()


def blank(binary,directory):
    source=fixture(directory);seed(binary,directory,source,96)
    terminal=start(binary,directory,source,96)
    try:
        settled(terminal,96)
        title=terminal.screen.locate('Mail ·')
        # The separator between two message cards isn't a clickable row.
        report(terminal,title['column']+2,title['row']+3,button=65)
        terminal.until(lambda:contains(terminal,93))
        terminal.finish()
        print('PASS wheel over blank mail-list spacing uses its pane rather than a row click target')
    except Exception:
        print(terminal.text());raise
    finally:terminal.close()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-fetch-wheel-') as tmp:
        pending(a.binary.resolve(),Path(tmp)/'pending')
        blank(a.binary.resolve(),Path(tmp)/'blank')


if __name__=='__main__':main()
