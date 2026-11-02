#!/usr/bin/env python3
"""Actual owned-PTY create-only Meet checkbox and truthful result screens."""
import argparse
import json
from pathlib import Path
import tempfile
import terminal_calendar_compose as ui
from terminal_calendar import Invitations, provider_state
from terminal_integration import Client, ACCOUNTS, require
from terminal_mouse import click, point
from terminal_meet_notes import meet_state


def scroll_review(t):
    for _ in range(35):
        t.send(b'\x04');t.gap(.01)


def run(binary, root, scenario, columns, rows, captures):
    fixture=Invitations(root);client=root/'client'
    t=ui.start(binary,client,fixture,scenario=scenario,columns=columns,rows=rows)
    try:
        ui.open_new(t);first,_=ui.new_dates();title='Fictional Meet notes planning'
        ui.ordinary_fields(t,title,first)
        ui.toggle(t,'Video: None','Video: Generate Google Meet')
        # Visibility and field/text semantics are checked in the actual terminal.
        ui.toggle(t,'[ ] Auto Meet AI notes' if columns>=100 else '[ ] Meet AI notes','[x] Auto Meet AI notes' if columns>=100 and scenario!='meet-no-permission' else 'needs Meet access' if columns>=100 else '[x] Meet AI notes')
        ui.capture(t,captures,scenario+f'-{columns}-checkbox')
        if scenario=='meet-no-permission':
            t.send(b'\x13');t.until(lambda:'Connect Meet settings' in t.text())
            ui.capture(t,captures,scenario+'-scope')
            t.send(b'\x1b');t.until(lambda:'New event' in t.text())
            # Reopen the guide to prove the choice and form were preserved.
            t.send(b'\x13');t.until(lambda:'Connect Meet settings' in t.text())
            with Client(binary,client,scenario=scenario,extra=fixture.options()) as c:require(provider_state(c)['writes']==0,'permission guide created event')
            return
        t.send(b'\x13');t.until(lambda:'Review new event' in t.text())
        ui.capture(t,captures,scenario+f'-{columns}-review')
        scroll_review(t);t.send(b'y')
        if scenario=='meet-ready':t.until(lambda:'confirmed by Google' in t.text())
        elif scenario=='meet-rejected':t.until(lambda:'Google refused the AI notes' in t.text())
        elif scenario=='meet-unapplied-unknown':t.until(lambda:'AI notes request unconfirmed' in t.text())
        elif scenario=='meet-conference-pending':t.until(lambda:'AI notes not sent yet' in t.text())
        ui.capture(t,captures,scenario+f'-{columns}-result')
        before=meet_state(root)
        t.send(b'r');t.gap(.15)
        t.until(lambda:'[r Check status' in t.text())
        require(meet_state(root)['patch_attempts']==before['patch_attempts'],'r changed Meet')
        for _ in range(3):t.send(b'y');t.gap(.05)
        require(meet_state(root)['patch_attempts']==before['patch_attempts'],'y resent uncertain/settled setting')
        with Client(binary,client,scenario=scenario,extra=fixture.options()) as c:
            require(provider_state(c)['writes']==1,'TUI created event more than once')
            require(c.request('cache.stats')['fixtureSends']==0,'TUI sent mail')
    except Exception:
        ui.capture(t,captures,scenario+f'-{columns}-failure')
        print(t.text(),flush=True)
        raise
    finally:t.close()


def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--capture-dir',type=Path);p.add_argument('--no-color',action='store_true');a=p.parse_args()
    ui.NO_COLOR=a.no_color
    cases=[('meet-ready',132,42),('meet-ready',66,30),('meet-no-permission',132,42),('meet-rejected',132,42),('meet-unapplied-unknown',132,42),('meet-conference-pending',132,42)]
    for index,(scenario,columns,rows) in enumerate(cases):
        with tempfile.TemporaryDirectory(prefix='omagma-meet-pty-') as temp:run(a.binary.resolve(),Path(temp),scenario,columns,rows,a.capture_dir)
    print(json.dumps({'ok':True,'cases':len(cases),'realOwnedPTY':True,'noColor':a.no_color,'scope':'new-events-only'}))


if __name__=='__main__':main()
