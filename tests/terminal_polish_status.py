#!/usr/bin/env python3
"""Focused mode/status/list/contact presentation checks in an owned fixture PTY."""
import argparse,re,tempfile
from pathlib import Path
from terminal_integration import require
from terminal_mouse import MouseTerminal, click
from terminal_mouse_screen import MouseScreen
from terminal_repaint import panel_interiors
from terminal_scroll_progress import fixture, options, seed


def run(binary, directory):
    terminal=MouseTerminal(binary,directory,columns=160,rows=42,screen_type=MouseScreen,environment={"NO_COLOR":None,"COLORTERM":"truecolor"})
    try:
        terminal.until(lambda: terminal.screen.locate('Synced ') is not None
                       and re.search(r'Mail · 1/32',terminal.text()) is not None)
        require('cache age' not in terminal.text(),'idle freshness still uses a frozen relative age')
        require(re.search(r'Mail · 1/32',terminal.text()),'mail title omits the current window position')
        terminal.send(b'jj')
        terminal.until(lambda: re.search(r'Mail · 3/32',terminal.text()) is not None)
        terminal.send(b'a')
        terminal.until(lambda: 'Contacts' in terminal.screen.lines()[0] and terminal.screen.locate('Alex Personal Fixture') is not None)
        require('Reader right' not in terminal.screen.lines()[0] and 'Inbox' not in terminal.screen.lines()[0],'contacts header retains stale mailbox/layout')
        terminal.until(lambda: terminal.screen.locate('Contacts · 1/2') is not None
                       and terminal.screen.locate('alex-personal@example.org') is not None)
        name=terminal.screen.locate('Alex Personal Fixture')
        email=terminal.screen.locate('alex-personal@example.org')
        require(name is not None and email is not None,'contact name/address pair missing')
        selected=('rgb',57,43,48)
        require(terminal.screen.styles[name['row']][name['column']][1]==selected,'contact name is not selected')
        require(terminal.screen.styles[email['row']][email['column']][1]==selected,'contact address is not selected with its name')
        terminal.send(b'q')
        terminal.until(lambda: 'Inbox' in terminal.screen.lines()[0]
                       and 'q Quit' in terminal.screen.lines()[-2])
        require('Contacts · / Search · n New · e Edit' not in terminal.screen.lines()[-1],'contacts key hints remain in mailbox status')
        terminal.send(b'c')
        terminal.until(lambda: 'Compose' in terminal.screen.lines()[0] and terminal.screen.locate('Subject:') is not None)
        require('Reader right' not in terminal.screen.lines()[0] and 'Inbox' not in terminal.screen.lines()[0],'compose header retains stale mailbox/layout')
        terminal.until(lambda: 'A Attach' in terminal.screen.lines()[-2] and 'Ctrl+S Review' in terminal.screen.lines()[-2])
        footer=terminal.screen.lines()[-2]
        require('A Attach' in footer and 'Ctrl+S Review' in footer,'composer critical actions are not in its sole footer')
        terminal.finish()
        print('PASS local status/header modes, window position, fixed sync time and two-row contact selection')
    except Exception:
        print(terminal.text())
        raise
    finally:terminal.close()


def narrow_capacity(binary, directory):
    source=fixture(directory)
    seed(binary,directory,source,96)
    terminal=MouseTerminal(binary,directory,extra=options(source,96),columns=48,rows=20,
        screen_type=MouseScreen,environment={"NO_COLOR":None,"COLORTERM":"truecolor"})
    try:
        terminal.until(lambda:terminal.screen.locate('Scroll fixture personal 096') is not None)
        terminal.send(b':layout below\r')
        for columns,rows,height,count in ((48,20,5,2),(100,30,8,3)):
            if terminal.columns!=columns or terminal.rows!=rows:terminal.resize(columns,rows)
            def ready():
                title=terminal.screen.locate('Mail · 1/32')
                last_subject=terminal.screen.locate(f'Scroll fixture personal {97-count:03}')
                if title is None or last_subject is None:return False
                return ('Fixture Sender' in terminal.screen.lines()[last_subject['row']+1]
                        and any(p[0]<=title['column']<p[1] and p[2]-1==title['row'] and p[3]-p[2]==height for p in panel_interiors(terminal.screen)))
            terminal.until(ready)
            title=terminal.screen.locate('Mail ·')
            panel=next((p for p in panel_interiors(terminal.screen)
                if p[0]<=title['column']<p[1] and p[2]-1==title['row']),None)
            require(panel is not None and panel[3]-panel[2]==height,'narrow fixture did not exercise the expected mail-window height')
            for index in range(count):
                subject=terminal.screen.locate(f'Scroll fixture personal {96-index:03}')
                require(subject is not None and subject['row']==panel[2]+index*3,'complete two-row card was dropped to reserve a trailing blank')
                require('Fixture Sender' in terminal.screen.lines()[subject['row']+1],'last visible mail lost its sender/excerpt row')
            # The last complete card is interactive on both rows; a resize
            # must preserve actual draw-derived hit areas rather than offsets.
            subject=terminal.screen.locate(f'Scroll fixture personal {97-count:03}')
            click(terminal,subject['column']+1,subject['row']+1)
            terminal.until(lambda:terminal.screen.locate(f'Mail · {count}/32') is not None)
            terminal.send(b'\x1b[H')
            terminal.until(lambda:terminal.screen.locate('Mail · 1/32') is not None)
        terminal.finish()
        print('PASS compact mail capacity: 48x20 shows two complete cards and 100x30 shows three, with clickable final sender rows')
    except Exception:
        print(terminal.text())
        raise
    finally:terminal.close()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-polish-status-') as directory:
        root=Path(directory)
        run(a.binary.resolve(),root/'status')
        narrow_capacity(a.binary.resolve(),root/'narrow')
if __name__=='__main__':main()
