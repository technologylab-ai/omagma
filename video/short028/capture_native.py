#!/usr/bin/env python3
"""Genuine v0.2.8 promotional takes; isolated PTYs and fictional mail only."""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'video/capture'), str(ROOT/'tests'), str(ROOT/'video/tools'), str(ROOT/'video/short027')]
from tape import Recorder, save, privacy_scan
from host_lock import owner, identity, start_ticks
from build_info import read_build_info
from terminal_integration import Client, require
from capture_fixture import make, seed, options, ACCOUNTS, WORK, MEETING_ID, payload_headers

SUBJECT = 'A useful paragraph for your agent chat 🌋'
EXCERPT = 'Copy this paragraph into your agent chat. Keep the useful details, leave the surrounding mail behind. 🌋'
BODY = 'Hi Morgan,\n\n'+EXCERPT+'\n\nEverything else can stay in your inbox.\n'
KNOWN = (*ACCOUNTS, 'maya@example.org', 'maya-home@example.net', 'launch@example.test',
         'booking@ember.example.org', 'notes@harbor.example.net', 'launch-briefing@example.test')


def reserve():
    lock = owner(); who = identity(lock) if lock else None
    require(lock and lock.get('token') == os.environ.get('HOST_TOKEN') and who
            and start_ticks(who[0]) == who[1], 'matching live host reservation required')


def setup(binary, directory):
    source, config, _ = make(directory)
    first = next(m for m in source.data[WORK]['baseline']['messages'] if m['id'] == MEETING_ID)
    first['snippet'] = 'One useful paragraph. Copy it, then get back to your day.'
    first['payload'] = {'mimeType':'text/plain', 'filename':'',
        'headers': payload_headers(first, SUBJECT, 'Maya Chen <maya@example.org>'),
        'body': {'size':len(BODY.encode()), 'data':base64.urlsafe_b64encode(BODY.encode()).decode().rstrip('=')}}
    source.stage(WORK, 'baseline')
    seed(binary, directory, source, config)
    preferences = directory/'film-ui.json'
    preferences.write_text(json.dumps({'schema':1, 'theme':'omagma', 'readerLayout':'right',
        'lastAccount':WORK, 'sendGraceSeconds':10})+'\n'); preferences.chmod(0o600)
    return source, config, preferences


def begin(binary, directory, source, config, preferences, name, environ=None):
    rec = Recorder(binary, directory, name,
        extra=options(source, config, '--account', WORK, '--ui-file', str(preferences)),
        columns=160, rows=42, environment=environ)
    try:
        rec.wait(lambda: 'Up to date' in rec.text() and SUBJECT in rec.text() and 'Hi Morgan,' in rec.text())
        rec.gap(.15)
        return rec
    except BaseException:
        rec.close(); raise


def mark(rec, name):
    rec.gap(.14); rec.mark(name)


def run(args, environment=None):
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=15)
    require(result.returncode == 0 and not result.stderr, 'offline CLI capture failed')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--out', type=Path, default=ROOT/'video/cache/short028')
    args = parser.parse_args(); reserve()
    binary = args.binary.resolve(); digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, 'capture binary changed')
    info = {'sha256':digest, **read_build_info(binary)}
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    receipts = {}
    with tempfile.TemporaryDirectory(prefix='omagma-film028-') as temporary:
        directory = Path(temporary).resolve()
        source, config, preferences = setup(binary, directory)
        extra = options(source, config)
        rec = begin(binary, directory, source, config, preferences, 'reader')
        try:
            mark(rec, 'context')
            rec.press('l', 'reader:focus', show=False); rec.gap(.1)
            rec.press('V', 'reader:move'); rec.wait(lambda: '[Select V]' in rec.text() and 'MOVE' in rec.text()); mark(rec, 'move')
            rec.press('jj0', 'reader:choose-start', show=False); rec.gap(.12); mark(rec, 'at-paragraph')
            rec.press(' ', 'reader:mark-start'); rec.wait(lambda:'[Copy y]' in rec.text() and 'CHAR' in rec.text()); mark(rec, 'marked')
            rec.press('$', 'reader:extend'); rec.gap(.12); mark(rec, 'excerpt')
            rec.press('y', 'reader:copy'); rec.wait(lambda:'terminal clipboard' in rec.text() and '[Copy y]' not in rec.text()); mark(rec, 'copied')
            clips = re.findall(rb'\x1b\]52;[a-z]*;([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)', bytes(rec.output))
            require(len(clips) == 1 and base64.b64decode(clips[0]).decode() == EXCERPT, 'captured clipboard excerpt differs from literal paragraph')
            receipts['reader'] = rec.finish(client_extra=extra)
            save(out/'reader.json', rec.tape(info), known=KNOWN)
            (out/'clipboard-proof.json').write_text(json.dumps({'literal':EXCERPT,
                'sha256':hashlib.sha256(EXCERPT.encode()).hexdigest(), 'writes':1,
                'privateOwnedPtyOnly':True, 'desktopClipboardUsed':False}, ensure_ascii=False, indent=2)+'\n')
        finally:
            if sys.exc_info()[0]:
                print(rec.text(), file=sys.stderr)
                save(out/'reader-failed.json', rec.tape(info), known=KNOWN)
            rec.close()

        editor_config = directory/'editor.vim'
        editor_config.write_text(r'''set termguicolors number nowrap noswapfile nobackup nowritebackup
set laststatus=2 showmode
set statusline=message.txt\ —\ private\ working\ copy\ \ \ :q\ returns\ to\ Omagma
highlight Normal guifg=#e8ebf1 guibg=#111620
highlight LineNr guifg=#8b95ab guibg=#111620
highlight CursorLineNr guifg=#ff9e61 guibg=#111620
highlight StatusLine guifg=#ff9e61 guibg=#392b30 gui=bold
highlight Search guifg=#111620 guibg=#ff9e61
''')
        editor_command = shlex.join(['/usr/bin/nvim', '--clean', '-u', str(editor_config), '-n', '-i', 'NONE'])
        rec = begin(binary, directory, source, config, preferences, 'editor', {'EDITOR':editor_command})
        try:
            rec.press('l', 'editor:reader', show=False); mark(rec, 'context')
            rec.press('e', 'editor:open'); rec.wait(lambda:'private working copy' in rec.text() and 'From:' in rec.text()); mark(rec, 'view')
            rec.press('/Copy this paragraph\r', 'editor:find', show=False); rec.gap(.15); mark(rec, 'paragraph')
            rec.press(':q!\r', 'editor:return', show=False)
            rec.wait(lambda:'Editor view closed' in rec.text() and SUBJECT in rec.text()); mark(rec, 'returned')
            with Client(binary, directory, extra=extra) as client:
                require(client.request('mail.read', WORK, messageId=MEETING_ID, cacheOnly=True)['bodyText'] == BODY, 'editor changed original mail')
                require(not client.request('draft.list', WORK)['drafts'], 'reader editor created a draft')
            receipts['editor'] = rec.finish(client_extra=extra)
            save(out/'editor.json', rec.tape(info), known=KNOWN)
        finally:
            if sys.exc_info()[0]:
                print(rec.text(), file=sys.stderr)
                save(out/'editor-failed.json', rec.tape(info), known=KNOWN)
            rec.close()

        rec = begin(binary, directory, source, config, preferences, 'send')
        try:
            rec.press('c', 'send:compose', show=False); rec.wait(lambda:'Subject:' in rec.text() and 'Attachments 0' in rec.text())
            rec.press('imaya@example.org\t\t\tA small hello from Omagma 🌋\t', 'send:headers', show=False)
            rec.press(b'\x1b[200~Hi Maya,\n\nThe launch notes are ready. See you soon!\n\nMorgan\x1b[201~', 'send:body', show=False)
            rec.press(b'\x1b', 'send:normal', show=False); rec.gap(.2)
            rec.press(b'\x13', 'send:review'); rec.wait(lambda:'Review send' in rec.text() and '[y Send]' in rec.text()); mark(rec, 'review')
            rec.click(*rec.locate('[y Send]'), 'send:confirm'); rec.wait(lambda:'Send now' in rec.text() and 'Sending in' in rec.text()); mark(rec, 'countdown')
            rec.wait(lambda:'Sending in 9s' in rec.text()); mark(rec, 'countdown-nine')
            rec.wait(lambda:'Sending in 8s' in rec.text()); mark(rec, 'countdown-eight')
            rec.press(b'\t', 'send:focus-now'); rec.gap(.15); mark(rec, 'now-focus')
            rec.press(b'\r', 'send:now'); rec.wait(lambda:'Send complete · provider accepted' in rec.text()); mark(rec, 'receipt')
            receipts['send'] = rec.finish(expected_sends=1, client_extra=extra)
            save(out/'send.json', rec.tape(info), known=KNOWN)
        finally:
            if sys.exc_info()[0]:
                print(rec.text(), file=sys.stderr)
                save(out/'send-failed.json', rec.tape(info), known=KNOWN)
            rec.close()
    # No account configuration or credentials are needed by these real commands.
    clean = dict(os.environ); clean.pop('HOME', None)
    for name, command in [('cli-index', ['cli','--help','commands']),
                          ('cli-command',['cli','--help','mail.read']),
                          ('cli-schema',['cli','--schema','mail.send'])]:
        text = run([str(binary),*command], clean); privacy_scan([text], known=KNOWN)
        (out/(name+'.txt')).write_text(text)
        if name == 'cli-schema': json.loads(text)
    (out/'native-receipt.json').write_text(json.dumps({'binary':info,'syntheticOnly':True,
        'liveProviderWrites':0,'fixtureSends':1,'scenes':receipts,'editorOriginalUnchanged':True,
        'allOwnedChildrenReaped':True}, ensure_ascii=False, indent=2)+'\n')
    print('Captured genuine reader/editor/Send now and offline CLI; fictional mail only')


if __name__ == '__main__': main()
