#!/usr/bin/env python3
"""Unsaved cached correspondents and isolated composer previews in owned PTYs."""
import argparse
import base64
import json
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, Client, require
from terminal_scroll_progress import fixture, repage
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen
from terminal_polish_compose import panel_text


def prepare(binary, directory):
    source = fixture(directory)
    for account in ACCOUNTS[:2]:
        for message in source.data[account]['baseline']['messages']:
            number = int(message['id'].rsplit('-', 1)[1])
            headers = message['payload']['headers']
            if account == ACCOUNTS[0] and number in (95, 96):
                address = 'caroline-new@example.test' if number == 96 else 'caroline-old@example.test'
                for header in headers:
                    if header['name'].lower() == 'from':
                        header['value'] = f'Caroline Composer <{address}>'
            elif account == ACCOUNTS[1] and number == 96:
                for header in headers:
                    if header['name'].lower() == 'from':
                        header['value'] = 'Caroline Work <caroline-work@example.test>'
            if number == 96:
                body = '\n'.join(f'ORIGINAL LINE {n:03} · fictional reply context.' for n in range(120))+'\n'
                message['payload']['body'] = {'size':len(body.encode()), 'data':base64.urlsafe_b64encode(body.encode()).decode().rstrip('=')}
            if account == ACCOUNTS[0] and number == 94:
                message['labelIds'] = ['SENT']
                for header in headers:
                    if header['name'].lower() == 'from': header['value'] = account
                    if header['name'].lower() == 'to': header['value'] = 'Caro Sent <caro-sent@example.test>'
        repage(source.data[account]['baseline'])
        source.stage(account, 'baseline')
    extra = source.options('--fixture-scenario', 'readonly', '--prefetch-bodies', '0')
    with Client(binary, directory, extra=extra) as client:
        for account in ACCOUNTS[:2]:
            client.request('mail.list', account, limit=96)
            client.request('mail.read', account, messageId='shared-msg-096')
        # This Sent recipient must come from committed metadata, never a
        # previously decoded or cached full body.
        absent = client.request('mail.read', ACCOUNTS[0], ok=False,
                                messageId='shared-msg-094', cacheOnly=True)
        require(absent['code']=='CacheMiss', 'Sent completion secretly relied on a cached body')
        before = client.request('cache.stats')
        projected = client.request('mail.recipients', ACCOUNTS[0], cacheOnly=True)
        require(client.request('cache.stats')['fixtureCalls']==before['fixtureCalls'],
                'recipient projection fetched provider data')
        values = projected['recipients']
        require(not projected['contactsIncluded'], 'correspondent suggestions required contacts permission')
        require(any(value['address']=='caroline-new@example.test' for value in values), 'uncategorized Inbox sender missing')
        require(any(value['address']=='caro-sent@example.test' for value in values), 'retained Sent recipient missing')
        require(all(value['address'].lower()!=ACCOUNTS[0].lower() for value in values), 'primary self entered suggestions')
        require(all(value['address']!='caroline-work@example.test' for value in values), 'another account leaked into projection')
        require(len({value['address'].lower() for value in values})==len(values), 'projection contains duplicates')
    return source, extra


def begin(binary, directory, extra):
    terminal = MouseTerminal(binary, directory, extra=extra, columns=160, rows=40, screen_type=MouseScreen)
    terminal.until(lambda:'ORIGINAL LINE 000' in terminal.text() and 'Up to date' in terminal.text())
    return terminal


def correspondents(binary, directory):
    source, extra = prepare(binary, directory)
    terminal = begin(binary, directory, extra)
    hold = source.root/'recipients.hold'
    entered = source.root/'recipients.entered'
    try:
        # The only provider enrichment is a bounded Sent metadata head. Hold
        # its first metadata request while typing and selecting local matches.
        current = json.loads(source.path(ACCOUNTS[0]).read_text())
        hold.write_text('Owned fictional Sent metadata hold\n')
        current['sync']['fixtureProgress'] = {'phase':'metadata','completed':0,
            'fixtureHold':hold.name,'fixtureEntered':entered.name}
        source.path(ACCOUNTS[0]).write_text(json.dumps(current))
        terminal.send(b'c')
        terminal.until(lambda:'Subject:' in terminal.text() and 'Draft preview' in terminal.text())
        require('ORIGINAL LINE 000' not in panel_text(terminal,'Draft preview'), 'new composer inherited Inbox body')
        terminal.send(b'icaro')
        terminal.until(lambda:'caroline-new@example.test' in terminal.text() and entered.exists())
        # Physical Ctrl+N, Ctrl+P and Enter select an unsaved correspondent
        # while the provider remains held, without changing another field.
        terminal.send(b'\x0e\x10\r')
        terminal.until(lambda:'caroline-new@example.test' in ''.join(terminal.screen.lines()))
        terminal.send(b'\t\t\tRecipient fixture\tOwn draft body')
        terminal.until(lambda:'Own draft body' in panel_text(terminal,'Draft preview'))
        require('ORIGINAL LINE' not in panel_text(terminal,'Draft preview'), 'draft preview shows unrelated incoming content')
        require(hold.exists(), 'background hold ended before cached completion')
        hold.unlink()
        terminal.send(b'\x1b\x13')
        terminal.until(lambda:'Sending account:' in terminal.text())
        with Client(binary,directory,extra=extra) as client:
            drafts = client.request('draft.list')['drafts']
            require(len(drafts)==1,'completion created or lost a draft')
            value = client.request('draft.read',draftId=drafts[0]['id'])
            require(value['to'][0]['address']=='caroline-new@example.test','Ctrl+N/P inserted another recipient')
            require(value['bodyText']=='Own draft body','completion/background fetch changed typed body')
            require(client.request('cache.stats')['fixtureSends']==0,'recipient test sent mail')
        terminal.finish()
        print('PASS recipients: unsaved Inbox/Sent metadata, no contacts permission, isolation/dedup and Ctrl+N/P during held background fetch')
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def preview(binary, directory):
    _, extra = prepare(binary,directory)
    terminal = begin(binary,directory,extra)
    try:
        terminal.send(b'r')
        terminal.until(lambda:'Subject:' in terminal.text() and 'Original message' in terminal.text())
        require('ORIGINAL LINE 000' in panel_text(terminal,'Original message'),'reply lost original context')
        terminal.send(b'\x04')
        terminal.until(lambda:'ORIGINAL LINE 000' not in panel_text(terminal,'Original message'))
        require('ORIGINAL LINE' in panel_text(terminal,'Original message'),'Ctrl+D erased original context')
        terminal.send(b'\x15')
        terminal.until(lambda:'ORIGINAL LINE 000' in panel_text(terminal,'Original message'))
        terminal.finish()
        print('PASS previews: reply original stays frozen and Ctrl+D/U scroll it without mailbox traversal')
    finally:
        terminal.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--case',choices=['all','correspondents','preview'],default='all')
    args=parser.parse_args()
    for name,case in [('correspondents',correspondents),('preview',preview)]:
        if args.case not in ('all',name):continue
        with tempfile.TemporaryDirectory(prefix='omagma-recipient-preview-') as value:
            case(args.binary.resolve(),Path(value))


if __name__=='__main__': main()
