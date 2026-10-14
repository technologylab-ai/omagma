"""Actual TUI exit while another local client occupies the vault worker."""
import json
import signal
import subprocess
import sys
import termios
import time

from terminal_integration import require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen
from terminal_pty import open_composer, saved_compose_frame


def authored_body(draft):
    fields = draft.get('recoveryFields')
    if fields is not None:
        require(len(fields) == 5, 'persisted recovery draft lost its authored fields')
        return fields[4]
    return draft['bodyText']


def run(binary, directory, backend, env, request):
    for kind in ('preferences', 'draft'):
        root = directory / ('tui-exit-' + kind)
        terminal = MouseTerminal(binary, root, extra=('--backend', str(backend), '--prefetch-bodies', '0'),
                                 environment=env, screen_type=MouseScreen, columns=120, rows=32)
        delayed = None
        try:
            try:
                terminal.until(lambda: 'Up to date' in terminal.text(), seconds=15)
            except AssertionError as error:
                raise AssertionError('vault TUI startup failed: ' + bytes(terminal.output[-5000:]).decode(errors='replace')) from error
            terminal.gap(.5)
            if kind == 'draft':
                previous_ids = {draft['id'] for draft in request('draft.list')['drafts']}
                open_composer(terminal)
                terminal.send(b'\t\t\t\tiInitial vault draft')
                terminal.until(lambda: 'Initial vault draft' in terminal.text())
                terminal.send(b'\x1b')
                terminal.until(lambda: saved_compose_frame(terminal), seconds=12)
                # A previous saved frame can remain visible during the next
                # debounce. Establish the exact persisted initial revision
                # before deliberately occupying the owner for the exit test.
                chosen = None
                observed = []
                deadline = time.monotonic() + 12
                while chosen is None and time.monotonic() < deadline:
                    response = request('draft.list', ok=None)
                    if not response['ok']:
                        require(response['error']['code'] == 'VaultBusy', 'initial draft listing failed')
                    else:
                        for draft in response['data']['drafts']:
                            if draft['id'] in previous_ids:
                                continue
                            loaded = request('draft.read', draftId=draft['id'], ok=None)
                            if not loaded['ok']:
                                require(loaded['error']['code'] == 'VaultBusy', 'initial draft read failed')
                                break
                            observed.append(dict(id=draft['id'], body=authored_body(loaded['data'])[:128]))
                            if authored_body(loaded['data']) == 'Initial vault draft':
                                chosen = draft
                                break
                    if chosen is None:
                        terminal.gap(.1)
                require(chosen is not None, 'initial exact draft revision did not persist before busy-exit setup; '
                        + json.dumps(observed[-3:]) + '\n' + terminal.text())
            # The existing five-second exit loop must not abandon either save.
            delayed = subprocess.Popen([str(binary), 'cli', '--backend', str(backend)], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            delayed.stdin.write(json.dumps(dict(id='busy-tui-' + kind, cmd='mail.refresh',
                                                account='personal@example.com', fixtureDelayMs=14000)).encode() + b'\n')
            delayed.stdin.close()
            terminal.gap(.3)
            require(delayed.poll() is None, 'fixture did not occupy the daemon worker')
            require(request('preferences.get', account='', ok=False)['code'] == 'VaultBusy', 'test did not establish busy admission')
            if kind == 'preferences':
                terminal.send(b':density comfortable\r')
                terminal.until(lambda: 'Comfortable' in terminal.text() or 'comfortable' in terminal.text())
            else:
                terminal.send(b'i\x05 + latest edit before exit')
                terminal.until(lambda: 'latest edit before exit' in terminal.text())
            before = time.monotonic()
            terminal.process.send_signal(signal.SIGTERM)
            deadline = before + 40
            while terminal.process.poll() is None and time.monotonic() < deadline:
                terminal.pump()
            require(terminal.process.poll() == 0, 'busy TUI exit lost a pending snapshot: ' + terminal.text())
            require(time.monotonic() - before > 5, 'busy exit regression did not cross the previous timeout')
            # Darwin hangs up the slave after its session leader exits. The
            # retained master still exposes the same complete tty attributes.
            descriptor = terminal.master if sys.platform == 'darwin' else terminal.slave
            require(termios.tcgetattr(descriptor) == terminal.settings, 'busy exit did not restore termios')
            require(delayed.wait(timeout=3) == 0, 'held worker did not finish')
            response = json.loads(delayed.stdout.read())
            require(response['ok'], 'held refresh did not finish successfully')
            if kind == 'preferences':
                require(request('preferences.get', account='')['preferences']['density'] == 'comfortable', 'exit lost latest preference revision')
            else:
                require(authored_body(request('draft.read', draftId=chosen['id'])) == 'Initial vault draft + latest edit before exit', 'exit lost latest authored draft')
            require(not list(root.rglob('index.json')), 'remote TUI wrote a plaintext cache')
            require(not list(root.rglob('ui.json')), 'remote TUI wrote plaintext preferences')
        finally:
            terminal.close()
            if delayed is not None:
                if delayed.poll() is None:
                    delayed.terminate()
                delayed.wait(timeout=5)
    print('PASS vault actual TUI busy exit: latest draft and preferences retained beyond5s', flush=True)
