#!/usr/bin/env python3
"""Five actual SGR mouse workflows in isolated PTYs; runtime grant required."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_cache import ProviderFixture, seed, metrics, digests
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal
from terminal_reader import reader_rectangle, reader_rows, reader_contains
from terminal_repaint import RepaintTerminal
from terminal_mouse_screen import MouseScreen

CASES = ("mouse-cached-navigation", "mouse-layout-wheel", "mouse-contacts-picker", "mouse-disabled", "mouse-editor-restore")
ENABLED = {1002, 1004, 1006}


class MouseTerminal(RepaintTerminal):
    def pump(self, seconds=.05):
        previous = len(self.output)
        super().pump(seconds)
        # Advertise pixel capability independently. The app must still force
        # cell-mode reporting when its logical width is capped at240.
        tail = bytes(self.output[max(0, previous-20):])
        query = b"\x1b[?1016$p"
        for match in re.finditer(re.escape(query), tail):
            if max(0, previous-20)+match.end() > previous:
                self.send(b"\x1b[?1016;2$y")


def point(terminal, literal, region=None):
    found = terminal.screen.locate(literal)
    require(found is not None, "expected visible mouse target absent")
    if region is not None:
        require(region[0] <= found["column"] < region[1] and region[2] <= found["row"] < region[3], "mouse target outside its actual pane")
    return found["column"], found["row"]


def report(terminal, x, y, button=0, release=False):
    require(0 <= x < terminal.columns and 0 <= y < terminal.rows, "mouse point outside owned physical tty")
    terminal.send(f"\x1b[<{button};{x+1};{y+1}{'m' if release else 'M'}".encode())


def click(terminal, x, y):
    report(terminal, x, y)
    report(terminal, x, y, release=True)


def list_point(terminal, index=0, sender=False, separator=False):
    title = terminal.screen.locate("Mail · [ ] Page")
    require(title is not None, "mail target pane not rendered")
    row = title["row"] + 1 + index*3 + (2 if separator else 1 if sender else 0)
    return title["column"] + 3, row


def contains(terminal, account, number):
    return reader_contains(terminal.screen, f"Synthetic {account} message {number:03}.")


def selected_mail(terminal, number):
    literal=f'Synthetic personal message {number:03};'
    found=terminal.screen.locate(literal)
    return found is not None and terminal.screen.styles[found['row']][found['column']][1]==('rgb',57,43,48)


def fixture_setup(binary, directory):
    fixture = ProviderFixture(directory)
    (fixture.root / "contacts").mkdir(mode=0o700)
    for account in ACCOUNTS:
        key=account.split('@')[0]
        shutil.copyfile(ROOT/'tests/fixtures/terminal/contacts'/f'{key}.json', fixture.root/'contacts'/f'{key}.json')
        source=fixture.data[account]['baseline']
        preview=next(m for m in source['messages'] if m['id']=='shared-msg-096')
        content=(f'Synthetic {account} message 096.\n'+
                 '\n'.join(f'Owned mouse reader scroll line {i:03} café.' for i in range(80))+'\n')
        data=content.encode()
        preview['payload']['body']={'size':len(data),'data':base64.urlsafe_b64encode(data).decode().rstrip('=')}
        sent=next(m for m in source['messages'] if m['id']=='shared-msg-090')
        sent['labelIds']=['SENT','UNREAD']
        fixture.stage(account,'baseline')
    seed(binary,directory,fixture,accounts=ACCOUNTS,bodies=('shared-msg-096','shared-msg-095','shared-msg-090'))
    contacts={}
    with Client(binary,directory,extra=fixture.options()) as client:
        for account in ACCOUNTS: contacts[account]=client.request('contacts.list',account)['contacts']
    saved=snapshot(binary,directory,fixture)
    for account in ACCOUNTS:fixture.stage(account,'baseline',held=True)
    return fixture,contacts,saved


def snapshot(binary,directory,fixture):
    result={}
    with Client(binary,directory,extra=fixture.options()) as client:
        for account in ACCOUNTS:
            result[account]={"contacts":client.request('contacts.list',account,cacheOnly=True)['contacts'],
                "operations":client.request('operation.list',account),"sends":metrics(client,account)['fixtureSends'],
                "bodyDigests":digests(directory,account)}
    return result


def start(binary,directory,fixture,extra=(),environment=None,columns=160,rows=40):
    return MouseTerminal(binary,directory,extra=fixture.options(*extra),screen_type=MouseScreen,
        environment={'NO_COLOR':None,'COLORTERM':'truecolor',**(environment or {})},columns=columns,rows=rows)


def modes(terminal, enabled=True):
    terminal.until(lambda:terminal.screen.mouse_modes==(ENABLED if enabled else set()))
    require(not any(mode in (1000,1016) and on for mode,on in terminal.screen.mouse_history), "app enabled unexpected click/pixel protocol")


def run_case(binary,directory,name):
    fixture,contacts,saved=fixture_setup(binary,directory)
    terminal=None
    try:
        extra=('--no-mouse',) if name=='mouse-disabled' else ()
        environment={}
        if name=='mouse-editor-restore':
            environment['EDITOR']=shlex.join([sys.executable,str(ROOT/'tests/fixtures/terminal/editor_mouse_fixture.py')])
        terminal=start(binary,directory,fixture,extra,environment)
        fixture.wait_entered(terminal.process,pump=terminal.pump)
        terminal.until(lambda:contains(terminal,ACCOUNTS[0],96))
        modes(terminal, name!='mouse-disabled')
        result={"sgrCellCoordinates":True,"defaultReporting":name!='mouse-disabled'}
        if name=='mouse-cached-navigation':
            click(terminal,*point(terminal,ACCOUNTS[1]))
            terminal.until(lambda:contains(terminal,ACCOUNTS[1],96))
            require(fixture.is_held(ACCOUNTS[0]),"cross-account cached click completed after the original worker released")
            click(terminal,*list_point(terminal,1,sender=True))
            terminal.until(lambda:contains(terminal,ACCOUNTS[1],95))
            # Release, right-click, shift-left, motion, border, blank separator
            # and footer inputs must not select another row or mutate mail.
            x,y=list_point(terminal,0)
            report(terminal,x,y,release=True);report(terminal,x,y,2);report(terminal,x,y,4);report(terminal,x,y,32)
            click(terminal,*list_point(terminal,0,separator=True))
            click(terminal,0,0);terminal.gap(.15)
            require(contains(terminal,ACCOUNTS[1],95),"ignored/non-left event changed selected mail")
            click(terminal,*point(terminal,'Sent'))
            terminal.until(lambda:contains(terminal,ACCOUNTS[1],90))
            click(terminal,*point(terminal,'Inbox'))
            terminal.until(lambda:contains(terminal,ACCOUNTS[1],96))
            click(terminal,*point(terminal,'Contacts'))
            terminal.until(lambda:contacts[ACCOUNTS[1]][0]['name'] in terminal.text())
            require(fixture.is_held(ACCOUNTS[0]),"navigation assertion ran after the original held worker released")
            result.update(accountClicked=True,mailSenderRowClicked=True,mailboxClicked=True,contactsClickedWhileHeld=True,ignoredReportsStable=True)
        elif name=='mouse-layout-wheel':
            observed=[]
            for columns,rows,layout in ((160,40,'right'),(100,30,'below'),(70,30,'below'),(251,40,'right')):
                if terminal.columns!=columns or terminal.rows!=rows:terminal.resize(columns,rows)
                terminal.send(b':layout '+layout.encode()+b'\r');terminal.gap(.15)
                terminal.until(lambda:terminal.screen.locate('Mail · [ ] Page') is not None)
                terminal.mouse_stage=f'{columns}x{rows}-reset-home'
                click(terminal,*list_point(terminal,0))
                terminal.until(lambda:'j/k Mail' in terminal.text())
                terminal.send(b'\x1b[H')
                terminal.until(lambda:selected_mail(terminal,96) and (reader_rectangle(terminal.screen) is None or contains(terminal,ACCOUNTS[0],96)))
                terminal.mouse_stage=f'{columns}x{rows}-click095'
                click(terminal,*list_point(terminal,1))
                terminal.until(lambda:selected_mail(terminal,95) and (reader_rectangle(terminal.screen) is None or contains(terminal,ACCOUNTS[0],95)))
                terminal.mouse_stage=f'{columns}x{rows}-wheel-down3'
                report(terminal,*list_point(terminal,0),button=65)
                terminal.until(lambda:selected_mail(terminal,92) and (reader_rectangle(terminal.screen) is None or contains(terminal,ACCOUNTS[0],92)))
                terminal.mouse_stage=f'{columns}x{rows}-wheel-up3'
                report(terminal,*list_point(terminal,0),button=64)
                terminal.until(lambda:selected_mail(terminal,95) and (reader_rectangle(terminal.screen) is None or contains(terminal,ACCOUNTS[0],95)))
                modes(terminal)
                observed.append({'columns':columns,'rows':rows,'layout':layout})
            # Hovered reader wheel must scroll the same full message, not mail.
            terminal.mouse_stage='reader-wheel-reset-home'
            click(terminal,*list_point(terminal,0));terminal.until(lambda:'j/k Mail' in terminal.text())
            terminal.send(b'\x1b[H');terminal.until(lambda:selected_mail(terminal,96) and contains(terminal,ACCOUNTS[0],96))
            rect=reader_rectangle(terminal.screen);require(rect is not None,'reader wheel target absent')
            click(terminal,rect['right']-2,rect['top']+2)
            terminal.until(lambda:'h/Esc/q List' in terminal.text())
            before=[text for _,text in reader_rows(terminal.screen)]
            terminal.mouse_stage='reader-wheel-down'
            report(terminal,rect['right']-2,rect['top']+2,65)
            terminal.until(lambda:[text for _,text in reader_rows(terminal.screen)]!=before)
            report(terminal,rect['right']-2,rect['top']+2,64)
            terminal.until(lambda:[text for _,text in reader_rows(terminal.screen)]==before)
            require(contains(terminal,ACCOUNTS[0],96),'reader wheel selected another mail')
            result.update(geometries=observed,wheelMovesThreeMailRows=True,readerWheelKeepsMessage=True)
        elif name=='mouse-contacts-picker':
            click(terminal,*point(terminal,'Contacts'))
            terminal.until(lambda:contacts[ACCOUNTS[0]][0]['name'] in terminal.text())
            target=contacts[ACCOUNTS[0]][1]
            click(terminal,*point(terminal,target['emails'][0]['address']))
            terminal.until(lambda:'Name:' in terminal.text() and target['name'] in terminal.text())
            terminal.send(b'\x1b');terminal.gap();terminal.send(b'\x1b');terminal.gap()
            # A local draft is allowed; provider writes remain forbidden.
            fixture.release();terminal.until(lambda:'Up to date' in terminal.text())
            terminal.send(b'c');terminal.until(lambda:'Compose' in terminal.text() and 'Subject:' in terminal.text())
            terminal.send(b'a');terminal.until(lambda:contacts[ACCOUNTS[0]][0]['name'] in terminal.text())
            target=contacts[ACCOUNTS[0]][0]
            click(terminal,*point(terminal,target['name']))
            terminal.until(lambda:'Compose' in terminal.text() and target['emails'][0]['address'] in terminal.text())
            require('Review send' not in terminal.text(),'contact picker click submitted/reviewed draft')
            result.update(contactEmailRowOpensLocalFields=True,pickerClickAddsRecipientOnly=True)
        elif name=='mouse-disabled':
            history=list(terminal.screen.mouse_history)
            click(terminal,*point(terminal,ACCOUNTS[1]));click(terminal,*list_point(terminal,1))
            report(terminal,*list_point(terminal,0),button=65);terminal.gap(.2)
            require(contains(terminal,ACCOUNTS[0],96),'--no-mouse accepted injectedSGR input')
            require(not any(on for _,on in history),'--no-mouse emitted a tracking-enable sequence')
            terminal.send(b'j');terminal.until(lambda:contains(terminal,ACCOUNTS[0],95))
            result.update(injectedReportsIgnored=True,trackingNeverEnabled=True,keyboardNavigationPreserved=True)
        else:
            fixture.release();terminal.until(lambda:'Up to date' in terminal.text())
            terminal.send(b'c');terminal.until(lambda:'Compose' in terminal.text() and 'Subject:' in terminal.text())
            terminal.send(b'e')
            terminal.until(lambda:terminal.editor_log.exists() and 'OWNED MOUSE EDITOR' in terminal.text())
            editor=json.loads(terminal.editor_log.read_text())
            require(editor['initialCanonical'] and editor['initialEcho'] and editor['stdinIsTty'], 'EDITOR did not inherit restored cooked terminal')
            require(terminal.screen.mouse_modes==set(),'mouse tracking remainsenabled insideEDITOR')
            terminal.send(b's')
            terminal.until(lambda:'Compose' in terminal.text() and 'Fictional mouse editor body.' in terminal.text())
            modes(terminal)
            # Click known draft field, enter literaltext, thenback; no send.
            click(terminal,*point(terminal,'Subject:'))
            terminal.send(b'Mouse field edit');terminal.gap(.1);terminal.send(b'\x1b');terminal.gap()
            require('Mouse field edit' in terminal.text(),'post-editor click reporting was not restored')
            terminal.send(b'q');terminal.until(lambda:terminal.screen.locate('Mail · [ ] Page') is not None)
            click(terminal,*list_point(terminal,1));terminal.until(lambda:contains(terminal,ACCOUNTS[0],95))
            result.update(editorCookedTerminal=True,trackingOffDuringEditor=True,trackingRestoredAfterEditor=True,postEditorClickWorks=True)
        result.update(screen_capture(terminal))
        result.update(terminal.finish())
        for _ in range(4):terminal.pump(.01)
        require(terminal.screen.mouse_modes==set(),'exit didnotdisable mouse reporting')
        after=snapshot(binary,directory,fixture)
        require(after==saved,'mouse workflow modified contacts/operationjournal/sends/immutablemailbodies')
        result.update(providerMutations=0,contactsUnchanged=True,operationJournalUnchanged=True,mailBodyDigestsUnchanged=True,exitReportingDisabled=True)
        return result
    except Exception as error:
        if terminal is not None:
            error.mouse_diagnostics=screen_capture(terminal)
            error.mouse_diagnostics['stage']=getattr(terminal,'mouse_stage',name)
        raise
    finally:
        for account in ACCOUNTS:fixture.release(account)
        if terminal is not None:terminal.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--build-mode',type=build_mode,default='debug')
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--case',action='append',choices=CASES)
    args=parser.parse_args();binary=args.binary.resolve();require(not args.output.exists(),'refusing previousmouse evidence overwrite')
    data={**read_build_info(binary,args.build_mode),'binarySha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
          'syntheticOnly':True,'liveWrites':False,'desktopUsed':False,'cases':[]}
    with tempfile.TemporaryDirectory(prefix='omagma-mouse-') as root:
        for name in CASES:
            if args.case and name not in args.case:continue
            started=time.monotonic()
            try:entry={'name':name,'passed':True,**run_case(binary,Path(root)/name,name)}
            except Exception as error:
                entry={'name':name,'passed':False,'error':f'{type(error).__name__}: {error}'}
                if hasattr(error,'mouse_diagnostics'):entry['diagnostics']=error.mouse_diagnostics
            entry['elapsedSeconds']=round(time.monotonic()-started,4);data['cases'].append(entry);print(json.dumps(entry),flush=True)
            if not entry['passed']:break
    data['passed']=bool(data['cases']) and all(c['passed'] for c in data['cases'])
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(data,indent=2)+'\n')
    return 0 if data['passed'] else 1


if __name__=='__main__':sys.exit(main())
