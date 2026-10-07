#!/usr/bin/env python3
"""Focused owned-PTY regressions for passive cache adoption, notices and gg."""
import argparse
import copy
import json
from pathlib import Path
import signal
import tempfile
import time

from terminal_background import Native
from terminal_cache import ProviderFixture, seed, contains_body, cached
from terminal_integration import Client, ACCOUNTS, require
from terminal_pty import Terminal
from terminal_status_screen import StatusScreen
from probes.cache_refresh_fixture import new_message, repage


def settle(tui):
    tui.until(lambda: "Up to date" in tui.text() and contains_body(tui, 96))
    tui.gap(1.2)  # Let the separate observer establish all account baselines.
    require("New mail" not in tui.text(), "startup announced existing mail")


def refresh(binary, directory, fixture, tui):
    owner = Native(binary, directory, fixture, "--force")
    try:
        deadline = time.monotonic() + 15
        while owner.process.poll() is None or owner.selector.get_map():
            require(time.monotonic() < deadline, "native refresh timed out")
            owner.pump(.01)
            tui.pump(.01)
        require(owner.process.returncode == 0 and not owner.stderr, "native background job failed")
    finally:
        owner.close()


def add_another(fixture, account, number=99):
    source = json.loads(fixture.path(account).read_text())
    message = copy.deepcopy(source['messages'][0])
    message.update(id=f'shared-msg-{number:03}', threadId='shared-thread-033',
                   internalDate=str(int(message['internalDate']) + 60000), labelIds=['INBOX','UNREAD'])
    for header in message['payload']['headers']:
        if header['name'].lower() == 'subject': header['value'] = f'Synthetic new arrival {number:03}'
    source['messages'].insert(0, message)
    checkpoint=str(1002+number-99)
    source['sync'] = {'historyId':checkpoint, 'historyPages':[{'historyId':checkpoint,'history':[
        {'id':checkpoint,'messagesAdded':[{'message':{'id':message['id'],'labelIds':['INBOX','UNREAD']}}]}]}]}
    fixture.path(account).write_text(json.dumps(source))


def run(binary, directory, case):
    fixture = ProviderFixture(directory)
    extra = fixture.options()
    if case == 'anchor-later-window':
        extra = fixture.options('--metadata-limit','96')
        with Client(binary,directory,extra=extra) as client:
            client.request('mail.refresh',ACCOUNTS[0],limit=96,prefetchLimit=32)
            client.request('mail.read',ACCOUNTS[0],messageId='shared-msg-040')
    else:
        seed(binary, directory, fixture, accounts=ACCOUNTS)
    tui = Terminal(binary, directory, extra=extra, screen_type=StatusScreen,
                   columns=132, rows=36, environment={'NO_COLOR':None,'COLORTERM':'truecolor'})
    try:
        settle(tui)
        if case == 'anchor-later-window':
            tui.send(b']')
            tui.until(lambda:contains_body(tui,64))
            for number in range(63,39,-1):
                tui.send(b'j')
                tui.until(lambda number=number:contains_body(tui,number))
            selected_rows = lambda: [row for row in range(3,32)
                                    if tui.screen.styles[row][40][1] == ('rgb',57,43,48)]
            before=selected_rows()
            require(bool(before),'selected later-window row missing')
            # Five additions, without deletions or label moves: the selected
            # message's logical index really moves from 57th to 62nd.
            source=json.loads(fixture.path(ACCOUNTS[0]).read_text())
            additions=[new_message(source,ACCOUNTS[0],n) for n in range(97,102)]
            source['messages']=sorted(source['messages']+additions,key=lambda m:-int(m['internalDate']))
            source['generation']=1001
            repage(source)
            source['sync']={'historyId':'1001','historyPages':[{'historyId':'1001','history':[
                {'id':'1001','messagesAdded':[{'message':{'id':m['id'],'labelIds':m['labelIds']}} for m in additions]}]}]}
            fixture.path(ACCOUNTS[0]).write_text(json.dumps(source))
            refresh(binary,directory,fixture,tui)
            tui.until(lambda:'New mail' in tui.text() and '5 new messages' in tui.text(),seconds=10)
            require(selected_rows()==before,'background insert shifted selected mail out of its screen row')
            tui.send(b'\x0c')
            tui.until(lambda:'New mail' not in tui.text())
            require(contains_body(tui,40),'background insert replaced the mail being read')
            tui.send(b'gg')
            tui.until(lambda:'delta 101' in tui.text())
        elif case == 'gg-whole-cache':
            tui.send(b']')
            tui.until(lambda: contains_body(tui,64))
            tui.send(b'gg')
            tui.until(lambda: contains_body(tui,96))
            tui.send(b']')
            tui.until(lambda: contains_body(tui,64))
            tui.send(b'lgg')
            tui.until(lambda: contains_body(tui,96))
            require('Reader right' in tui.text(), 'gg unexpectedly expanded the reader')
        else:
            fixture.stage(ACCOUNTS[0],'delta')
            refresh(binary,directory,fixture,tui)
            tui.until(lambda:'New mail' in tui.text() and '2 new messages' in tui.text(),seconds=10)
            require(ACCOUNTS[0] in tui.text(), 'arrival notice lost account identity')
            # A genuine newer head is adopted without touching Ctrl+R; the old
            # selected message remains selected/readable after the card clears.
            require('098' in tui.text() and '097' in tui.text(), 'new rows not adopted automatically')
            if case == 'accumulate-and-dismiss':
                add_another(fixture,ACCOUNTS[0])
                fixture.stage(ACCOUNTS[1],'delta')
                refresh(binary,directory,fixture,tui)
                tui.until(lambda:'3 new messages' in tui.text() and '2 new messages' in tui.text(),seconds=10)
                require(ACCOUNTS[0] in tui.text() and ACCOUNTS[1] in tui.text(), 'per-account accumulation lost identity')
                tui.send(b'h')
                tui.until(lambda:'New mail' not in tui.text())
                require(contains_body(tui,96), 'passive reload moved the selected reader')
                tui.gap(2.1)
                require('New mail' not in tui.text(), 'dismissed arrivals were replayed by the observer')
                tui.send(b'lgg')
                tui.until(lambda:'Synthetic new arrival 099' in tui.text())
            elif case == 'main-only-and-wheel':
                tui.send(b'a')
                tui.until(lambda:'Contacts' in tui.text() and 'New mail' not in tui.text())
                fixture.stage(ACCOUNTS[1],'delta')
                refresh(binary,directory,fixture,tui)
                tui.gap(1.3)
                require('New mail' not in tui.text(), 'notice distracted Contacts')
                tui.send(b'q')
                tui.until(lambda:'Inbox' in tui.text())
                add_another(fixture,ACCOUNTS[0])
                refresh(binary,directory,fixture,tui)
                tui.until(lambda:'New mail' in tui.text() and '1 new message' in tui.text(),seconds=10)
                tui.send(b'\x1b[<65;30;13M')
                tui.until(lambda:'New mail' not in tui.text())
                tui.send(b'c')
                tui.until(lambda:'Subject:' in tui.text() and '[f Alias]' in tui.text()
                          and 'A Attach' in tui.text())
                tui.send(b'\t\t\tiUnsent local subject\x1b')
                tui.until(lambda:'Unsent local subject' in tui.text())
                add_another(fixture,ACCOUNTS[1])
                refresh(binary,directory,fixture,tui)
                tui.gap(1.3)
                require('New mail' not in tui.text(), 'notice distracted composing')
                require('Unsent local subject' in tui.text(), 'cache observation overwrote the draft')
                tui.send(b'q')
                tui.until(lambda:'Inbox' in tui.text())
                fixture.stage(ACCOUNTS[2],'delta')
                refresh(binary,directory,fixture,tui)
                tui.until(lambda:'New mail' in tui.text() and '2 new messages' in tui.text(),seconds=10)
                # Card is at the upper right; a click dismisses it without
                # activating a covered reader link/message underneath.
                tui.send(b'\x1b[<0;100;5M\x1b[<0;100;5m')
                tui.until(lambda:'New mail' not in tui.text())
                add_another(fixture,ACCOUNTS[0],100)
                refresh(binary,directory,fixture,tui)
                tui.send(b'h')
                tui.gap(1.4)
                require('New mail' not in tui.text(), 'pre-interaction arrivals reappeared after deferred observation')
            else: raise AssertionError('unknown case')
        tui.finish(signal_mode=signal.SIGTERM)
    except Exception:
        print(tui.text())
        raise
    finally:
        tui.close()
    print('PASS',case)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,required=True)
    cases=['gg-whole-cache','accumulate-and-dismiss','main-only-and-wheel','anchor-later-window']
    parser.add_argument('--case',choices=cases)
    args=parser.parse_args()
    for case in [args.case] if args.case else cases:
        with tempfile.TemporaryDirectory(prefix='omagma-tui-arrivals-') as temporary:
            run(args.binary.resolve(),Path(temporary),case)


if __name__=='__main__': main()
