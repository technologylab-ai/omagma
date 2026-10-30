#!/usr/bin/env python3
"""Owned-PTY Drive delivery controls; disconnected fixtures only.

Covers the oversized-selection dialog (Cancel keeps the browser, Drive all
imports without uploading), per-row delivery buttons, [Upload all], draft
save/reopen persistence, the backend plan header and the blocked review for
Bcc and a missing Drive grant, scrolled end to end with j/k. No provider
write or upload may occur.
"""
import argparse, json, subprocess, tempfile
from pathlib import Path
from terminal_integration import ACCOUNTS, FIXTURES, Client, no_core_dump, require
from terminal_mouse import MouseTerminal, click, point
from terminal_mouse_screen import MouseScreen
from terminal_pty import wait_saved_compose

SUBJECT = 'Drive delivery fixture'


def stats(directory):
    with Client(BINARY, directory) as client:
        return client.request('cache.stats')


def subject_of(item):
    # Autosave keeps unfinished editor text as recoveryFields (To, Cc, Bcc,
    # Subject, Body) until an explicit Save/Review; both forms are valid.
    fields = item.get('recoveryFields') or []
    return item.get('subject') or (fields[3] if len(fields) > 3 else '')


def saved_draft(directory):
    with Client(BINARY, directory) as client:
        drafts = [item for item in client.request('draft.list')['drafts'] if subject_of(item) == SUBJECT]
        require(len(drafts) == 1, 'delivery edits created another draft')
        return client.request('draft.read', draftId=drafts[0]['id'])


def delivery(attachment):
    return attachment.get('delivery') or 'attach'


def scroll_review(terminal, key, reached, limit=60):
    """Scroll the review with its own j/k keys until reached(); returns the
    presses used. Every press must redraw, so a dead key fails, not spins."""
    presses = 0
    while not reached():
        require(presses < limit, 'review scroll never reached the expected text')
        before = terminal.text()
        terminal.send(key)
        terminal.until(lambda: terminal.text() != before)
        presses += 1
    return presses


def run(binary, directory):
    terminal = MouseTerminal(binary, directory, columns=160, rows=40, screen_type=MouseScreen)
    try:
        terminal.until(lambda: terminal.screen.mouse_tracking_mode == 1002 and 'Ready' in terminal.text())
        terminal.send(b'c')
        terminal.until(lambda: 'Subject:' in terminal.text() and 'Attachments 0' in terminal.text())
        # Bcc stays selectable with Drive; only the review blocks the send.
        terminal.send(f'ipeer@example.test\t\thidden@example.test\t{SUBJECT}\tSynthetic note.\x1b'.encode())
        terminal.until(lambda: 'Synthetic note.' in terminal.text())
        wait_saved_compose(terminal, 0)
        before = stats(directory)
        large = directory / 'report-final.bin'
        with large.open('wb') as output:
            output.truncate(26 * 1024 * 1024)
        terminal.send(b'A')
        terminal.until(lambda: 'Attach file · local draft' in terminal.text() and 'Path:' in terminal.text())
        terminal.send(str(large).encode() + b'\r')
        # The backend selection plan opens the dialog before any import, with
        # the all-Attach message figure and the Auto split.
        terminal.until(lambda: 'Too large to attach' in terminal.text() and '[ Auto (a) ]' in terminal.text()
                       and '[ Drive all (d) ]' in terminal.text() and '[ Keep (k) ]' in terminal.text()
                       and 'message ≈' in terminal.text() and '1 from Drive (26.0 MiB)' in terminal.text())
        # Cancel/Esc returns to the browser; nothing was imported.
        terminal.send(b'\x1b')
        terminal.until(lambda: 'Too large to attach' not in terminal.text() and 'Attach file · local draft' in terminal.text())
        require(saved_draft(directory)['attachments'] == [], 'cancelled oversized selection imported a file')
        terminal.send(b'\r')
        terminal.until(lambda: 'Too large to attach' in terminal.text())
        terminal.send(b'd')
        terminal.until(lambda: 'Attachments 1' in terminal.text() and '[Drive        ]' in terminal.text())
        wait_saved_compose(terminal, 1)
        draft = saved_draft(directory)
        require([delivery(item) for item in draft['attachments']] == ['drive'], 'Drive all was not saved per file')
        # Keep stages an oversized file as Attach; the row says it is too large.
        archive = directory / 'archive.bin'
        with archive.open('wb') as output:
            output.truncate(26 * 1024 * 1024)
        terminal.send(b'A')
        terminal.until(lambda: 'Attach file · local draft' in terminal.text())
        terminal.send(str(archive).encode() + b'\r')
        terminal.until(lambda: 'Too large to attach' in terminal.text())
        terminal.send(b'k')
        terminal.until(lambda: 'Attachments 2' in terminal.text() and '· too large' in terminal.text())
        wait_saved_compose(terminal, 2)
        require([delivery(item) for item in saved_draft(directory)['attachments']] == ['drive', 'attach'], 'Keep changed delivery')
        at = terminal.screen.locate('archive.bin')
        require(at is not None, 'kept file not visible')
        click(terminal, ''.join(terminal.screen.cells[at['row']]).index('[x]') + 1, at['row'])
        terminal.until(lambda: 'Attachments 1' in terminal.text() and terminal.screen.locate('archive.bin') is None)
        wait_saved_compose(terminal, 1)
        # The backend plan reaches the header and the composer warning line.
        terminal.until(lambda: 'Drive 1/16' in terminal.text()
                       and "Drive can't be used while Bcc has recipients" in terminal.text())
        terminal.send(b'\x13')
        terminal.until(lambda: "Can't send yet" in terminal.text() and '[y Send]' not in terminal.text()
                       and "Drive isn't connected for" in terminal.text() and '[Connect Drive]' in terminal.text())
        # The Drive size is the backend's estimate, accepted as a measurement.
        terminal.until(lambda: 'MIME: ≈' in terminal.text() and '· estimate' in terminal.text())
        require('SizeUnavailable' not in terminal.text(), 'Drive estimate was rejected as an unavailable size')
        terminal.send(b'y')
        terminal.until(lambda: 'Fix the items above first.' in terminal.text())
        # Connect Drive has initial focus and shows the full safe command only.
        terminal.send(b'\r')
        terminal.until(lambda: 'omagma terminal-auth authorize --account' in terminal.text() and 'drive-upload' in terminal.text())
        # Reasons and the command lead the review; the Drive block ends it.
        # Reach each end with the review's own j/k scroll, symmetrically.
        down = scroll_review(terminal, b'j', lambda: 'Drive files stay in your Drive after sending.' in terminal.text())
        up = scroll_review(terminal, b'k', lambda: "Drive can't be used while Bcc has recipients" in terminal.text()
                           and "Drive isn't connected for" in terminal.text()
                           and 'omagma terminal-auth authorize --account' in terminal.text())
        require(up == down, 'review scroll lost or skipped rows')
        require('[y Send]' not in terminal.text() and 'Send unavailable · Back to reduce files' not in terminal.text(),
                'blocked review offered Send or the generic size advice')
        after = stats(directory)
        require(after['fixtureSends'] == before['fixtureSends'] == 0, 'blocked Drive review sent mail')
        require(after['fixtureCalls'] == before['fixtureCalls'], 'import, save, plan or review contacted the provider')
        terminal.send(b'n')
        terminal.until(lambda: 'Compose' in terminal.text() and 'Subject:' in terminal.text())
        terminal.send(b'\x1b')
        terminal.until(lambda: terminal.screen.locate('Drafts') is not None and 'Subject:' not in terminal.text())
        click(terminal, *point(terminal, 'Drafts'))
        terminal.until(lambda: SUBJECT in terminal.text())
        terminal.send(b'\r')
        terminal.until(lambda: 'Subject:' in terminal.text() and '[Drive        ]' in terminal.text())
        # The read-only plan adds the warning row after reopening. Locate the
        # mouse target only once that layout has arrived.
        terminal.until(lambda: 'Drive 1/16' in terminal.text()
                       and "Drive can't be used while Bcc has recipients" in terminal.text())
        # The fixed-width delivery button cycles Drive → Attach on click.
        click(terminal, *point(terminal, '[Drive        ]'))
        terminal.until(lambda: '[Attach       ]' in terminal.text())
        wait_saved_compose(terminal, 1)
        require([delivery(item) for item in saved_draft(directory)['attachments']] == ['attach'], 'delivery click was not saved')
        terminal.until(lambda: '[Upload all]' in terminal.text() and 'Drive 0/16' in terminal.text())
        click(terminal, *point(terminal, '[Upload all]'))
        terminal.until(lambda: '[Drive        ]' in terminal.text() and '[Upload all]' not in terminal.text())
        wait_saved_compose(terminal, 1)
        require([delivery(item) for item in saved_draft(directory)['attachments']] == ['drive'], 'Upload all was not saved')
        final = stats(directory)
        require(final['fixtureSends'] == 0 and final['fixtureCalls'] == before['fixtureCalls'], 'delivery edits wrote remotely')
        terminal.finish()
        print('PASS Drive delivery: dialog, row/Upload all controls, save/reopen and blocked review without writes')
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    narrow(binary, directory)


def narrow(binary, directory):
    """Narrow composers use two lines per file and wrap the warning."""
    terminal = MouseTerminal(binary, directory, columns=64, rows=40, screen_type=MouseScreen)
    try:
        terminal.until(lambda: 'Ready' in terminal.text() and terminal.screen.locate('Drafts') is not None)
        click(terminal, *point(terminal, 'Drafts'))
        terminal.until(lambda: SUBJECT in terminal.text())
        terminal.send(b'\r')
        terminal.until(lambda: 'Subject:' in terminal.text() and '[Drv     ]' in terminal.text())
        name = terminal.screen.locate('report-final.bin')
        button = terminal.screen.locate('[Drv     ]')
        require(name is not None and button is not None and button['row'] == name['row'] + 1,
                'narrow row did not place the delivery button on its own line')
        require('[x]' in ''.join(terminal.screen.cells[button['row']]), 'narrow row lost its remove control')
        terminal.until(lambda: 'Drv 1/16' in terminal.text())
        terminal.finish()
        print('PASS Drive delivery narrow: two-line rows and compact plan header')
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def progress(binary, directory, scenario):
    """Opt-in: a fixture scenario whose account has drive-upload and whose
    sends report Drive progress. Stop must leave the draft with receipts."""
    terminal = MouseTerminal(binary, directory, columns=160, rows=40, screen_type=MouseScreen,
                             extra=('--fixture-scenario', scenario))
    try:
        terminal.until(lambda: 'Ready' in terminal.text())
        terminal.send(b'c')
        terminal.until(lambda: 'Subject:' in terminal.text())
        terminal.send(f'ipeer@example.test\t\t\t{SUBJECT} progress\tSynthetic note.\x1b'.encode())
        wait_saved_compose(terminal, 0)
        video = directory / 'video.bin'
        with video.open('wb') as output:
            output.truncate(30 * 1024 * 1024)
        terminal.send(b'A')
        terminal.until(lambda: 'Attach file · local draft' in terminal.text())
        terminal.send(str(video).encode() + b'\r')
        terminal.until(lambda: 'Too large to attach' in terminal.text())
        terminal.send(b'd')
        wait_saved_compose(terminal, 1)
        terminal.send(b'\x13')
        # Positive path: an estimated Drive measurement leaves Send enabled.
        terminal.until(lambda: 'From Drive 1' in terminal.text() and '[y Send]' in terminal.text()
                       and 'Drive files stay in your Drive after sending.' in terminal.text()
                       and 'MIME: ≈' in terminal.text() and "Can't send yet" not in terminal.text())
        terminal.send(b'y')
        terminal.until(lambda: 'uploads start when the countdown ends' in terminal.text() or 'Sending "' in terminal.text())
        terminal.until(lambda: 'Sending "' in terminal.text() and '[Cancel send]' in terminal.text(), seconds=40)
        # Before Gmail the Sending panel, status and say lines agree: Drive
        # work first, message not sent yet, never Submitting.
        terminal.until(lambda: 'Message: waits for uploads' in terminal.text() and 'message not sent yet' in terminal.text(), seconds=40)
        require('Submitting' not in terminal.text(), 'status said Submitting while Drive files were uploading')
        terminal.until(lambda: 'uploading' in terminal.text() or 'uploaded · private' in terminal.text(), seconds=40)
        terminal.send(b'\t\r')
        # Keep sending has initial focus; Tab then Enter chooses Stop.
        terminal.until(lambda: 'Stop sending?' in terminal.text() and '[Keep sending]' in terminal.text())
        terminal.send(b'\t\r')
        terminal.until(lambda: 'Message not sent' in terminal.text() and '[Retry preparation]' in terminal.text(), seconds=40)
        with Client(binary, directory, scenario=scenario) as client:
            require(client.request('cache.stats')['fixtureSends'] == 0, 'stopped Drive preparation sent mail')
        terminal.send(b'\x1b')
        terminal.until(lambda: 'Message not sent' not in terminal.text() and 'Subject:' in terminal.text())
        terminal.finish()
        print('PASS Drive delivery progress: countdown, per-file progress, confirmed Stop with receipts')
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def raw_one_shot(client, family, verb, arguments):
    """One-shot run that returns (exit code, reply) without the success helper."""
    argv = [str(client.binary), family, verb, '--fixtures', '--fixture-root', str(FIXTURES),
            '--cache-dir', str(client.directory / 'cache'), *client.extra, '--account', ACCOUNTS[0], *arguments]
    result = subprocess.run(argv, input=b'', capture_output=True, cwd=client.directory,
                            env=client.environment, timeout=12, preexec_fn=no_core_dump)
    lines = result.stdout.splitlines()
    require(len(lines) == 1, 'one-shot stdout was not exactly one protocol frame')
    reply = json.loads(lines[0])
    require(reply.get('version') == 1 and reply.get('account') in (None, ACCOUNTS[0]), 'one-shot reply lost its envelope')
    return result.returncode, reply


def cli(binary, directory):
    from terminal_cli_parity import one_shot
    deck = directory / 'deck.pdf'
    deck.write_bytes(b'%PDF-synthetic\n')
    raw = directory / 'raw.zip'
    raw.write_bytes(b'PK\x03\x04synthetic')
    with Client(binary, directory) as client:
        before = client.request('cache.stats')
        drafts = client.request('draft.list')
        base = ['--to', 'peer@example.test', '--subject', 'CLI delivery fixture', '--body', 'Synthetic.']
        one_shot(client, 'mail', 'send', [*base, '--attach-file', str(raw), '--upload-file', str(directory / '.' / 'raw.zip'),
                 '--operation-id', 'cli-delivery-conflict'], error='ConflictingAttachmentDelivery')
        one_shot(client, 'mail', 'send', [*base, '--file', str(deck), '--file', str(deck), '--operation-id', 'cli-delivery-twice'],
                 error='DuplicateAttachmentFile')
        one_shot(client, 'mail', 'send', [*base, '--file', str(deck), '--attachment-mode', 'x'], error='InvalidAttachmentMode')
        one_shot(client, 'draft', 'create', [*base, '--attachment-mode', 'auto', '--upload-file', str(raw)], error='AttachmentModeRequiresFile')
        one_shot(client, 'mail', 'read', ['--message-id', 'shared-msg-001', '--dry-run'], error='DryRunRequiresDraftSource')
        # All-Attach oversized sends are refused before any import, naming the flags.
        big = directory / 'big.bin'
        with big.open('wb') as output:
            output.truncate(26 * 1024 * 1024)
        refused = one_shot(client, 'mail', 'send', [*base, '--file', str(big), '--operation-id', 'cli-delivery-large'],
                           error='AttachmentsTooLarge')
        require(refused['message'].startswith('attachments are too large:')
                and any(hint.startswith('--attachment-mode auto') for hint in refused['hints'])
                and f'--upload-file {big}: share this file from Drive' in refused['hints']
                and refused['files'][0]['size'] == 26 * 1024 * 1024, 'oversized refusal omitted its hints or files')
        forced = one_shot(client, 'mail', 'send', [*base, '--attach-file', str(big), '--operation-id', 'cli-delivery-forced'],
                          error='AttachmentsTooLarge')
        require(forced['message'].startswith('files forced with --attach-file')
                and forced['hints'][0] == f'change --attach-file {big} to --upload-file {big}', 'forced refusal hint wrong')
        # A missing Drive grant names the complete authorization, never drive-upload alone.
        missing = one_shot(client, 'mail', 'send', [*base, '--upload-file', str(raw), '--operation-id', 'cli-delivery-auth'],
                           error='DriveNotConnected')
        hint = missing['hints'][0]
        require('omagma terminal-auth authorize --account' in hint and 'mail-read' in hint and hint.count('drive-upload') == 1,
                'missing grant hint did not keep existing capabilities')
        # Positive dry run: a plan that fits is printed with ok:true.
        planned = one_shot(client, 'mail', 'send', [*base, '--attachment-mode', 'auto', '--file', str(deck), '--dry-run'])
        planned_data = planned.get('plan', planned)
        require(planned.get('status', planned_data.get('status')) == 'planned' and planned_data.get('blockers') in (None, []),
                'fitting dry run was not reported as planned')
        # Blocked dry run (Bcc with Drive): a plan, not an error; the CLI exits
        # non-zero (CommandFailed) and nothing is imported, saved or sent.
        blocked_code, blocked = raw_one_shot(client, 'mail', 'send', [*base, '--bcc', 'hidden@example.test', '--attachment-mode', 'auto',
                                             '--file', str(deck), '--upload-file', str(raw), '--dry-run'])
        data = blocked.get('data') or {}
        plan = data.get('plan', data)
        require(blocked_code != 0 and blocked.get('ok') is False and 'error' not in blocked, 'blocked dry run changed its envelope')
        require(data.get('status', plan.get('status')) == 'blocked' and plan.get('blockers'), 'dry run accepted Drive with Bcc')
        require(data.get('dryRun', plan.get('dryRun')) is True, 'blocked dry run was not marked as a dry run')
        require(client.request('draft.list') == drafts, 'dry run saved a draft')
        require(client.request('cache.stats')['fixtureCalls'] == before['fixtureCalls'], 'dry run contacted the provider')
        # An explicit flag wins over --file regardless of order; saving never uploads.
        draft = one_shot(client, 'draft', 'create', [*base, '--file', str(raw), '--upload-file', str(raw), '--file', str(deck)])
        require([(item['filename'], item.get('delivery') or 'attach') for item in draft['attachments']]
                == [('raw.zip', 'drive'), ('deck.pdf', 'attach')], 'one-shot deliveries were not resolved canonically')
        after = client.request('cache.stats')
        require(after['fixtureSends'] == before['fixtureSends'] and after['fixtureCalls'] == before['fixtureCalls'],
                'CLI planning or draft saving contacted the provider')
    print('PASS Drive delivery CLI: canonical flags, dry run without writes, saved deliveries')


def main():
    global BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--drive-scenario', help='fixture scenario with drive-upload and Drive progress (opt-in)')
    args = parser.parse_args()
    BINARY = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='omagma-drive-delivery-') as temporary:
        for name in ('tui', 'cli', 'progress'):
            (Path(temporary) / name).mkdir()
        run(BINARY, Path(temporary) / 'tui')
        cli(BINARY, Path(temporary) / 'cli')
        if args.drive_scenario:
            progress(BINARY, Path(temporary) / 'progress', args.drive_scenario)
        else:
            print('SKIP Drive delivery progress: pass --drive-scenario NAME to run the send/Stop flow')


BINARY = None
if __name__ == '__main__': main()
