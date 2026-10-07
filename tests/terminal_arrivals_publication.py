#!/usr/bin/env python3
"""Actual fictional new-mail/HTML TUI capture; owned PTY and offscreen Qt only.

Run only inside the coordinator's host reservation. Mail arrivals are committed
through real fixture history refreshes; the card and every glyph come from the
running executable. No real config/mail, mapped window or desktop input is used.
"""
from __future__ import annotations
import argparse
import base64
import copy
import html
import json
from pathlib import Path
import shutil
import signal
import struct
import tempfile

from terminal_arrivals import refresh
from terminal_html import screen_capture
from terminal_html_screen import HtmlScreen
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_pty import Terminal
from terminal_reader import reader_contains
from terminal_ui import theme_path
import terminal_publication as publication
from probes.cache_refresh_fixture import repage

SUBJECT = "Launch briefing: small volcano, big plans 🌋🔥"
FULL_LINK = "https://updates.example.org/r/launch/0.2.5?utm_source=email&utm_medium=briefing&utm_campaign=autumn&recipient=morgan-cedar&signature=" + "c9e18a7f" * 8
RECEIPT_LINK = "https://billing.example.org/account/receipt/2026-10-07?view=download&ref=workspace-mail&tracking=" + "e42bd591" * 8
BODY = (
    '<html><body><h1>Hello Morgan 🌋</h1>'
    '<p><strong>A calmer inbox. A little more firepower.</strong> 🔥</p>'
    '<ul><li>Fresh mail arrives quietly, without moving what you are reading.</li>'
    '<li>Reply, attach a file 📎, and get on with your day.</li></ul>'
    '<p><strong>Launch notes:</strong> <a href="' + html.escape(FULL_LINK, quote=True) + '">' + html.escape(FULL_LINK) + '</a><br>'
    '<strong>Your receipt:</strong> <a href="' + html.escape(RECEIPT_LINK, quote=True) + '">' + html.escape(RECEIPT_LINK) + '</a></p>'
    '<table><tr><th>Workspace</th><th>Status</th><th>Next step</th></tr>'
    '<tr><td>Cedar Studio</td><td>Ready ✓</td><td>Ship something good 🚀</td></tr></table>'
    '<p><img src="https://images.example.org/briefing/studio.jpg" alt="Cedar Studio launch board"></p>'
    '<p>Magma regards, <em>The Cedar crew</em></p></body></html>'
)
PALETTE = '''# Fictional capture palette, following Omagma's public landing colors.
background = "#0e121b"
foreground = "#f4f0f7"
cursor = "#f4f0f7"
accent = "#ec7a35"
selection = "#352732"
dark_foreground = "#8f8aa1"
cyan = "#7bd8de"
green = "#93ca9a"
yellow = "#e8b48c"
red = "#ef7b84"
color0 = "#0e121b"
color1 = "#ef7b84"
color2 = "#93ca9a"
color3 = "#e8b48c"
color4 = "#ec7a35"
color5 = "#ba98ce"
color6 = "#7bd8de"
color7 = "#f4f0f7"
color8 = "#8f8aa1"
color9 = "#f8969d"
color10 = "#b3dbb8"
color11 = "#f4d0b3"
color12 = "#f6a467"
color13 = "#d0b4df"
color14 = "#a2e7eb"
color15 = "#ffffff"
'''


def prepared_fixture(directory):
    source = publication.fixture(directory)
    for account in ACCOUNTS:
        baseline = source.data[account]['baseline']
        message = baseline['messages'][0]
        encoded = BODY.encode()
        message['snippet'] = 'A calmer inbox. A little more firepower. 🔥 Launch notes, a receipt, and no wall of tracking URLs.'
        message['sizeEstimate'] = len(encoded)
        message['payload']['body'] = {'size': len(encoded), 'data': base64.urlsafe_b64encode(encoded).decode().rstrip('=')}
        for header in message['payload']['headers']:
            name = header['name'].lower()
            if name == 'subject': header['value'] = SUBJECT
            elif name == 'from': header['value'] = 'Cedar Studio <hello@example.org>'
            elif name == 'to': header['value'] = f'Morgan <{account}>'
        message['internalDate'] = '1791354000000'
        repage(baseline)
        source.stage(account, 'baseline')
    return source


def seed(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        for account in ACCOUNTS:
            client.request('mail.refresh', account, label='INBOX', limit=40, prefetchLimit=40)
            client.request('labels.list', account)
            message = client.request('mail.read', account, messageId=publication.FIRST_MESSAGE_ID, cacheOnly=True)
            require(message['subject'] == SUBJECT and FULL_LINK in html.unescape(message['bodyHtml']), 'authored HTML/full link was not cached intact')
            require(client.request('cache.stats', account)['fixtureSends'] == 0, 'publication fixture sent mail')
    require(client.process.returncode == 0 and not client.stderr, 'publication seed failed cleanup')


def arrival_wave(source, account, count, history_id):
    data = json.loads(source.path(account).read_text())
    template = data['messages'][0]
    titles = ('Design review is ready ✨', 'A small win for your inbox ☕', 'Your build just landed 🚀')
    added = []
    for index in range(count):
        item = copy.deepcopy(template)
        identity = f'arrival-{account.split("@")[0]}-{history_id}-{index}'
        item.update(id=identity, threadId=identity, historyId=str(history_id),
                    internalDate=str(int(template['internalDate']) + (index + 1) * 60000),
                    labelIds=['INBOX', 'UNREAD'], snippet='A short update from your fictional workspace.')
        text = f'Hello Morgan,\n{titles[index]}\nCheers,\nThe Cedar crew\n'.encode()
        item['payload']['mimeType'] = 'text/plain'
        item['payload']['body'] = {'size': len(text), 'data': base64.urlsafe_b64encode(text).decode().rstrip('=')}
        for header in item['payload']['headers']:
            if header['name'].lower() == 'subject': header['value'] = titles[index]
            elif header['name'].lower() == 'message-id': header['value'] = f'<{identity}@example.org>'
            elif header['name'].lower() == 'content-type': header['value'] = 'text/plain; charset=utf-8'
        added.append(item)
    data['messages'] = sorted(data['messages'] + added, key=lambda item: -int(item['internalDate']))
    data['generation'] = history_id
    repage(data)
    data['sync'] = {'historyId': str(history_id), 'historyPages': [{'historyId': str(history_id), 'history': [
        {'id': str(history_id), 'messagesAdded': [{'message': {'id': item['id'], 'labelIds': item['labelIds']}} for item in added]}]}]}
    source.path(account).write_text(json.dumps(data, ensure_ascii=False))


def snapshot(binary, directory):
    source = prepared_fixture(directory)
    seed(binary, directory, source)
    theme_path(directory).write_text(PALETTE)
    tui = Terminal(binary, directory, extra=source.options(), screen_type=HtmlScreen,
        columns=160, rows=40, environment={'NO_COLOR': None, 'COLORTERM': 'truecolor', 'TZ': 'UTC0'})
    try:
        tui.until(lambda: reader_contains(tui.screen, 'Hello Morgan') and 'Up to date' in tui.text())
        tui.send(b'2:layout below\r:split below 25\r')
        tui.until(lambda: 'work@example.com' in tui.screen.lines()[0] and 'Reader below' in tui.screen.lines()[0]
                  and reader_contains(tui.screen, 'Launch notes'))
        tui.gap(1.2)
        require(not any('─ New mail ' in row for row in tui.screen.lines()), 'capture startup announced existing cached mail')
        # Two observations of personal mail demonstrate real accumulation;
        # work owns its own independent arrival serial/count.
        arrival_wave(source, ACCOUNTS[0], 2, 1001)
        arrival_wave(source, ACCOUNTS[1], 2, 1001)
        refresh(binary, directory, source, tui)
        tui.until(lambda: any('─ New mail ' in row for row in tui.screen.lines()) and '2 new messages' in tui.text(), seconds=10)
        arrival_wave(source, ACCOUNTS[0], 1, 1002)
        refresh(binary, directory, source, tui)
        tui.until(lambda: '3 new messages' in tui.text() and '2 new messages' in tui.text(), seconds=10)
        require(reader_contains(tui.screen, 'Hello Morgan'), 'arrivals moved the selected HTML reader')
        tui.gap(.06)
        frame = screen_capture(tui)
        visible = '\n'.join(frame['currentCells'])
        require('personal@example.com' in visible and 'work@example.com' in visible, 'card lost account identity')
        require('signature=' not in visible and 'utm_campaign=' not in visible and 'tracking=' not in visible,
                'link shortening did not remove tracking-wall presentation')
        require('https://' in visible and 'example.org' in visible and '🌋' in visible and '📎' in visible, 'capture omitted shortened links or emoji')
        tui.finish(signal_mode=signal.SIGTERM)
        return frame
    except Exception:
        print(tui.text())  # Owned fictional mail only.
        raise
    finally:
        tui.close()


FRAME_QML = publication.QML.replace('rows: 34', 'rows: 40').replace('property int padding: 24', 'property int padding: 24\n  property int bannerHeight: 62')
FRAME_QML = FRAME_QML.replace('2 * root.padding\n    visible:', '2 * root.padding + root.bannerHeight\n    visible:')
FRAME_QML = FRAME_QML.replace('color: "#111620"', 'color: "#0a0d14"')
FRAME_QML = FRAME_QML.replace('      Repeater {', '''      Rectangle {
        x: 12; y: 12; width: parent.width - 24; height: parent.height - 24
        color: "#0e121b"; radius: 14; border.width: 1; border.color: "#453029"
      }
      Image { x: root.padding; y: 20; width: 34; height: 34; source: "__LOGO__"; fillMode: Image.PreserveAspectFit }
      Text { x: root.padding + 46; y: 21; text: "omagma"; color: "#f6a467"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 23; font.bold: true }
      Text { x: root.padding + 164; y: 28; text: "terminal mail"; color: "#b6b0c4"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14 }
      Repeater {''')
FRAME_QML = FRAME_QML.replace('y: root.padding + modelData.y * root.cellHeight', 'y: root.padding + root.bannerHeight + modelData.y * root.cellHeight')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/images/omagma-tui-arrivals.png')
    parser.add_argument('--copy-pictures', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omagma-arrivals-publication-') as temporary:
        directory = Path(temporary)
        frame = snapshot(args.binary.resolve(), directory / 'fixture')
        publication.QML = FRAME_QML.replace('__LOGO__', (ROOT / 'assets/omagma-logo.png').as_uri())
        publication.render_snapshots((frame,), directory / 'render', lambda _: output)
    width, height = struct.unpack('>II', output.read_bytes()[16:24])
    if args.copy_pictures:
        pictures = Path.home() / 'Pictures'
        pictures.mkdir(exist_ok=True)
        shutil.copyfile(output, pictures / output.name)
    print(f'PUBLIC SYNTHETIC {output.name}: {width}x{height}; actual accumulated per-account card/HTML/short URLs')


if __name__ == '__main__':
    main()
