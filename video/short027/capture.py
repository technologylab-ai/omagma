#!/usr/bin/env python3
"""Genuine v0.2.7 feature tapes. Owned PTYs, synthetic accounts, no sends.
Run only under the coordinator's verified cooperative HOST_TOKEN reservation.
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'video/capture'),str(ROOT/'tests'),str(ROOT/'video/tools')]
from tape import Recorder, save
from build_info import read_build_info
from host_lock import owner,identity,start_ticks
from terminal_integration import Client,require
from terminal_arrivals_publication import arrival_wave
from terminal_arrivals import refresh
from capture_fixture import make,options,seed,ACCOUNTS,WORK,MEETING_ID,MEETING_SUBJECT,BOOKING_ID,BOOKING_SUBJECT,REPORT_ID,REPORT_SUBJECT,NOTE,COMPOSE_BODY,FILES
CURRENT_OUT=None
CURRENT_INFO=None
KNOWN=(*ACCOUNTS,'maya@example.org','maya-home@example.net','launch@example.test','booking@ember.example.org','notes@harbor.example.net','launch-briefing@example.test')

def reservation():
    value=owner();who=identity(value) if value else None
    require(value and value.get('token')==os.environ.get('HOST_TOKEN') and who and start_ticks(who[0])==who[1],'matching live coordinator HOST_TOKEN required')

def command(rec,text,name=None):rec.press(':'+text+'\r',name or 'command:'+text,show=False)
def click(rec,label,name):rec.gap(.15);rec.click(*rec.locate(label),name);rec.gap(.1)
def mark(rec,name,**info):
    rec.gap(.15);rec.mark(name,**info)
    if CURRENT_OUT is not None:save_tape(rec,CURRENT_OUT,CURRENT_INFO)
def ready(rec):
    rec.wait(lambda:'Up to date' in rec.text() and MEETING_SUBJECT in rec.text(),name='ready');rec.gap(.3)
    rec.press('gg','inbox:top',show=False);rec.wait(lambda:'I · Respond' in rec.text() and 'Hi Morgan,' in rec.text());rec.gap(.15)
def recorder(binary,directory,source,config,name):
    preferences=directory/'film-ui.json'
    if not preferences.exists():preferences.write_text(json.dumps({'schema':1,'theme':'omagma','sendGraceSeconds':10})+'\n');preferences.chmod(0o600)
    return Recorder(binary,directory,name,extra=options(source,config,'--account',WORK,'--ui-file',str(preferences)),columns=160,rows=42,environment={'TZ':'Europe/Vienna'})
def save_tape(rec,out,info):
    value=rec.tape(info);value['environment']='owned synthetic PTY; Omagma theme; 160x42; Europe/Vienna; no live provider'
    save(out/(rec.name+'.json'),value,known=KNOWN)
def search(rec,query):rec.press('/'+query+'\r','cache:search',show=False);rec.wait(lambda:query in rec.text() and 'Cache search' in rec.text());rec.gap(.2)
def no_send(binary,directory,extra):
    with Client(binary,directory,extra=extra) as client:
        require(sum(client.request('cache.stats',account)['fixtureSends'] for account in ACCOUNTS)==0,'capture sent mail')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--expected-sha256',required=True);p.add_argument('--out',type=Path,default=ROOT/'video/cache/short027');p.add_argument('--scene',action='append',choices=['main','meeting','compose','forward','newmail'])
    a=p.parse_args();reservation();binary=a.binary.resolve();sha=hashlib.sha256(binary.read_bytes()).hexdigest();require(sha==a.expected_sha256,'capture binary changed');info=read_build_info(binary);out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);(out/'assets').mkdir(exist_ok=True)
    global CURRENT_OUT,CURRENT_INFO
    CURRENT_OUT,CURRENT_INFO=out,info
    wanted=set(a.scene or ['main','meeting','compose','forward','newmail']);prior=out/'capture-receipt.json';receipts=json.loads(prior.read_text()).get('scenes',{}) if prior.exists() else {}
    with tempfile.TemporaryDirectory(prefix='omagma-short027-') as temporary:
        directory=Path(temporary);source,config,files=make(directory);extra=options(source,config);seed(binary,directory,source,config)
        if 'main' in wanted:
            rec=recorder(binary,directory,source,config,'main')
            try:
                ready(rec);mark(rec,'main')
                rec.press(b'\x10','palette:open');rec.wait(lambda:'Actions' in rec.text() and '[Run]' in rec.text());mark(rec,'palette');rec.type('label','palette:query',delay=.06);rec.wait(lambda:'Assign labels' in rec.text() and 'Manage labels' in rec.text());mark(rec,'palette-filtered');rec.press(b'\x1b','palette:back',show=False);rec.wait(lambda:'Actions' not in rec.text())
                rec.press('?','help:open');rec.wait(lambda:'Help' in rec.text());rec.press('/label\r','help:search',show=False);rec.wait(lambda:'Find: label' in rec.text() or 'Find:label' in rec.text());mark(rec,'help');rec.press(b'\x1b','help:clear',show=False);rec.gap(.3);rec.press('q','help:back',show=False);rec.wait(lambda:'Keyboard & mouse' not in rec.text())
                rec.press('T','theme:open');rec.wait(lambda:'[Apply]' in rec.text() and 'Omagma' in rec.text());mark(rec,'theme');click(rec,'[Cancel]','theme:cancel');rec.wait(lambda:'[Apply]' not in rec.text())
                command(rec,'labels');rec.wait(lambda:'Manage labels' in rec.text() and '[c Color]' in rec.text());click(rec,'Projects','labels:choose-projects');click(rec,'[c Color]','color:open');rec.wait(lambda:'Color · Projects' in rec.text() and '[Save color]' in rec.text());rec.press(b'\x1b[Z'*3+b'orange','color:filter',show=False);rec.wait(lambda:'Filter: orange' in rec.text() and 'Orange' in rec.text());mark(rec,'label-colors');rec.press(b'\x1b','color:cancel',show=False);rec.wait(lambda:'Color · Projects' not in rec.text());rec.press(b'\x1b','manager:back',show=False);rec.wait(lambda:'Manage labels' not in rec.text())
                rec.press('  m','labels:open',show=False);rec.wait(lambda:'[Apply 0]' in rec.text() and '[-]' in rec.text() and '[x]' in rec.text());mark(rec,'labels');rec.press(' j ','labels:stage');rec.wait(lambda:'[Apply 2]' in rec.text());mark(rec,'labels-staged');click(rec,'[Cancel]','labels:cancel');rec.wait(lambda:'[Cancel]' not in rec.text());rec.press(b'\x1b','selection:clear',show=False);rec.gap(.1)
                command(rec,'scope');rec.wait(lambda:'Mail action scope' in rec.text() and '[Open]' in rec.text());mark(rec,'scope');rec.press(b'\x1b','scope:back',show=False);rec.gap(.1)
                search(rec,'Release notes');rec.wait(lambda:'Keyboard-first' in rec.text());rec.press('q','cache:back-before-find',show=False);rec.wait(lambda:'Cache search' not in rec.line(0) and 'Keyboard-first' in rec.text());command(rec,'find calm');rec.wait(lambda:'Find 1/' in rec.text());mark(rec,'find');rec.press('n','find:next');rec.wait(lambda:'Find 2/' in rec.text());mark(rec,'find-next');rec.press('N','find:previous');rec.wait(lambda:'Find 1/' in rec.text());rec.press(b'\x1b','find:done',show=False)
                search(rec,'Release notes');command(rec,'save-search Release notes');rec.wait(lambda:'Search saved for this account' in rec.text());command(rec,'saved-searches');rec.wait(lambda:'Saved searches' in rec.text() and 'Release notes' in rec.text());mark(rec,'saved-search');rec.press(b'\x1b','saved:back',show=False);receipts['main']=rec.finish(client_extra=extra);save_tape(rec,out,info)
            finally:rec.close()
        if 'meeting' in wanted:
            rec=recorder(binary,directory,source,config,'meeting')
            try:
                ready(rec);rec.wait(lambda:'I · Respond' in rec.text());mark(rec,'meeting');rec.press('I','meeting:review');rec.wait(lambda:'Meeting · review reply' in rec.text() and '[o Join]' in rec.text() and '20 min' in rec.text());mark(rec,'meeting-review');require('https://meet.example.test/launch' in rec.text() and 'UID:' not in rec.text(),'friendly review Join target differs');rec.press('o','meeting:join');rec.wait(lambda:'Mock browser target validated' in rec.text());mark(rec,'join',validatedTarget='https://meet.example.test/launch',account=WORK,dryOpen=True,invitationMode='normal');rec.press('v','meeting:details');rec.wait(lambda:'UID:' in rec.text() and '[v Less]' in rec.text());mark(rec,'meeting-details');rec.press(b'\x1b','meeting:back',show=False);receipts['meeting']=rec.finish(client_extra=extra);save_tape(rec,out,info)
            finally:rec.close()
        if 'compose' in wanted:
            rec=recorder(binary,directory,source,config,'compose')
            try:
                ready(rec);rec.press('c','compose:open');rec.wait(lambda:'Attachments 0' in rec.text() and 'Subject:' in rec.text());rec.press('imaya','recipient:query',show=False);rec.wait(lambda:'Recipients' in rec.text() and 'Maya Chen' in rec.text());mark(rec,'recipient');rec.press(b'\r','recipient:choose');rec.wait(lambda:'To: Maya Chen <maya@example.org>' in rec.text());mark(rec,'recipient-named');rec.press(b'\t\t\tA calmer inbox. A better day.\t','compose:headers',show=False);rec.press(b'\x1b[200~'+COMPOSE_BODY.encode()+b'\x1b[201~','compose:body',show=False);rec.wait(lambda:'hello()' in rec.text());rec.press(b'\x1b','compose:normal',show=False);mark(rec,'composer');rec.press(b'i\x1b[200~\nExtra note.\x1b[201~','composer:edit',show=False);rec.wait(lambda:'Extra note.' in rec.text());mark(rec,'composer-edit');rec.press(b'\x1a','composer:undo');rec.wait(lambda:'Extra note.' not in rec.text());mark(rec,'composer-undo');rec.press(b'\x1b','composer:normal-after-undo',show=False)
                command(rec,'sender');rec.wait(lambda:'Choose sender' in rec.text() and 'launch@example.test' in rec.text());mark(rec,'sender');rec.press(b'\x1b','sender:cancel',show=False);rec.gap(.1)
                rec.press('A','files:open');rec.wait(lambda:'Path:' in rec.text() and '[Attach]' in rec.text());rec.press(b'\x15Documents/\r','files:folder',show=False);rec.wait(lambda:'other-project.txt' in rec.text());rec.press(b'\x15Documents/ERUPTION','files:filter',show=False);rec.wait(lambda:all(name in rec.text() for name in FILES) and 'other-project.txt' not in rec.text());rec.press(b'\t\t\t\t j j ','files:check-three',show=False);rec.wait(lambda:'3 selected' in rec.text());rec.press(b'\x1b[Z'*4+b'\x15Documents/ERUPTION','files:retain-filter',show=False);rec.wait(lambda:'Path: Documents/ERUPTION' in rec.text() and all(name in rec.text() for name in FILES));rec.press(b'\t'*4,'files:list-focus',show=False);mark(rec,'files');label='[Attach]';click(rec,label,'files:attach');rec.wait(lambda:'Attachments 3' in rec.text() and 'Attach file ·' not in rec.text());mark(rec,'attached');rec.press(b'\x13','send:review');rec.wait(lambda:'Review send' in rec.text() and '[y Send]' in rec.text());mark(rec,'send-review');click(rec,'[y Send]','send:queue');rec.wait(lambda:'[Undo' in rec.text() and 'Sending in' in rec.text());mark(rec,'countdown');rec.gap(1.05);mark(rec,'countdown-nine');rec.press(b'\x1a','send:undo');rec.wait(lambda:'[Undo' not in rec.text() and 'Subject:' in rec.text());mark(rec,'send-canceled');no_send(binary,directory,extra);receipts['compose']=rec.finish(client_extra=extra);save_tape(rec,out,info)
            finally:rec.close()
            # Keep this scene's local draft from polluting the forward shot.
            with Client(binary,directory,extra=extra) as client:
                for draft in client.request('draft.list',WORK)['drafts']:client.request('draft.discard',WORK,draftId=draft['id'])
        if 'forward' in wanted:
            rec=recorder(binary,directory,source,config,'forward')
            try:
                ready(rec);rec.press('j','booking:select');rec.wait(lambda:'Lisbon is calling.' in rec.text());rec.press('f','forward:open');rec.wait(lambda:'[Keep formatting k]' in rec.text());mark(rec,'format-choice');rec.press('k','forward:keep');rec.wait(lambda:'formatted original' in rec.text() and 'Subject:' in rec.text());rec.press('imaya@example.org\t\t\t\t','forward:headers',show=False);rec.press(b'\x1b[200~'+NOTE.encode()+b'\x1b[201~','forward:note',show=False);rec.press(b'\x1b','forward:normal',show=False);rec.wait(lambda:'Lisbon trip' in rec.text());mark(rec,'forward');rec.press(b'\x13','forward:review');rec.wait(lambda:'Review send' in rec.text() and '[Back]' in rec.text());
                with Client(binary,directory,extra=extra) as client:
                    rows=client.request('draft.list',WORK)['drafts'];require(len(rows)==1,'forward retained unexpected draft count');draft=client.request('draft.read',WORK,draftId=rows[0]['id']);require(draft['bodyText'].startswith(NOTE) and draft['bodyFormat']=='markdown','forward changed exact Markdown note');require(draft.get('original') is not None,'forward did not freeze source HTML');preview=client.request('draft.preview',WORK,draftId=draft['id']);require('EMBER AIR' in preview['bodyHtml'] and '<table' in preview['bodyHtml'],'HTML preview lost source booking layout');opened=client.request('draft.open-preview',WORK,draftId=draft['id']);require(opened['fixture'] and not opened['opened'],'preview unexpectedly launched desktop');shutil.copyfile(opened['path'],out/'assets/browser.html');(out/'preview.json').write_text(json.dumps(preview,ensure_ascii=False,indent=2));(out/'forward-proof.json').write_text(json.dumps({'originalHtmlSha256':hashlib.sha256(draft['original']['bodyHtml'].encode()).hexdigest(),'sourceId':BOOKING_ID,'bodyFormat':draft['bodyFormat'],'bodyText':draft['bodyText'],'attachmentCount':len(draft['attachments']),'nativePreviewPathPrivate':True,'browserDryOpen':True},ensure_ascii=False,indent=2))
                click(rec,'[Back]','forward:back');receipts['forward']=rec.finish(client_extra=extra);save_tape(rec,out,info)
            finally:rec.close()
        if 'newmail' in wanted:
            rec=recorder(binary,directory,source,config,'newmail')
            try:
                ready(rec);rec.gap(1.2);require('New mail' not in rec.text(),'startup replayed arrivals');arrival_wave(source,WORK,2,1001);refresh(binary,directory,source,rec);rec.wait(lambda:'New mail' in rec.text() and '2 new messages' in rec.text());mark(rec,'newmail');require(WORK in rec.text(),'newmail omitted receiving account');rec.press('j','newmail:auto-hide');rec.wait(lambda:'New mail' not in rec.text());mark(rec,'newmail-hidden');receipts['newmail']=rec.finish(client_extra=extra);save_tape(rec,out,info)
            finally:rec.close()
        no_send(binary,directory,extra)
    receipt={'binarySha256':sha,'buildInfo':info,'synthetic':True,'liveProviderWrites':0,'fixtureSends':0,'scenes':receipts,'files':files,'allChildrenReaped':True};(out/'capture-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n');print('Captured genuine v0.2.7 states; all synthetic; zero sends.')
if __name__=='__main__':main()
