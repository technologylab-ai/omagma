#!/usr/bin/env python3
"""Local migration/activation/start acceptance with synthetic files and tokens."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import select
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import traceback

from vault_daemon import PASSWORD, displayed_recovery, prompt, require

ACCOUNT = 'personal@example.com'


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def digest_parts(*parts):
    return hashlib.sha256(b''.join(part.encode() + b'\0' for part in parts)).hexdigest()


class Evidence:
    def __init__(self, path=None, build_info=None):
        self.path = path
        self.value = dict(buildInfo=build_info, syntheticOnly=True, liveWrites=False,
                          events=[], passed=False)
        self.save()

    def save(self):
        if self.path is not None:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.value, indent=2) + '\n')
            self.path.chmod(0o600)

    def process(self, stage, argv, **kwargs):
        event = dict(stage=stage, argv=[str(arg) for arg in argv])
        self.value['events'].append(event)
        self.save()
        began = time.monotonic()
        try:
            result = subprocess.run(argv, **kwargs)
            event.update(exitCode=result.returncode,
                         stdout=result.stdout.decode(errors='replace'),
                         stderr=result.stderr.decode(errors='replace'))
            return result
        except BaseException as error:
            event['error'] = repr(error)
            raise
        finally:
            event['elapsedSeconds'] = round(time.monotonic() - began, 6)
            self.save()


def command_result(result):
    return f'exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}'


def listener_held(socket):
    try:
        lease = (socket.parent / 'daemon.lock').open('rb')
    except FileNotFoundError:
        return False
    with lease:
        try:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(lease.fileno(), fcntl.LOCK_UN)
    return False


def wait_stopped(socket):
    # Socket removal precedes release of the listener lease. A new owner must
    # not race that final shutdown step after the stop acknowledgement.
    deadline = time.monotonic() + 5
    while (socket.exists() or listener_held(socket)) and time.monotonic() < deadline:
        time.sleep(.02)
    require(not socket.exists() and not listener_held(socket), 'detached owned daemon did not release its listener')


def cleanup_detached(binary, env, socket, start_pending, evidence):
    # A failed start command can leave its successfully launched owner alive.
    # Only use this test's private socket; detached PIDs are not safe kill handles.
    if start_pending and not socket.exists():
        deadline = time.monotonic() + 10
        while not socket.exists() and time.monotonic() < deadline:
            time.sleep(.02)
    if socket.exists():
        result = evidence.process('cleanup-stop',
                                  [str(binary), 'vault', 'stop', '--socket', str(socket)],
                                  env=env, capture_output=True, timeout=20)
        require(result.returncode == 0, 'owned detached cleanup failed: ' + command_result(result))
    wait_stopped(socket)


def run(binary, root, evidence=None):
    evidence = evidence or Evidence()
    env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_CACHE_HOME=str(root / 'cache-home'))
    for name in ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME'):
        Path(env[name]).mkdir(mode=0o700)
    source = root / 'source'
    source.mkdir(mode=0o700)
    cache = source / 'cache'
    config = source / 'config.json'
    grants = source / 'grants.json'
    preferences = source / 'ui.json'
    clients = source / 'desktop.json'
    credentials = source / 'credentials'
    credentials.mkdir(mode=0o700)
    client_id = 'synthetic-migration.apps.googleusercontent.com'
    private_json(clients, {'installed': {'client_id': client_id, 'client_secret': 'SyntheticClientSecretOnly',
                                       'redirect_uris': ['http://127.0.0.1']}})
    private_json(config, {'credentialStore': 'file', 'credentialDirectory': str(credentials),
                          'oauthClientFile': str(clients), 'accounts': [{'address': ACCOUNT, 'profile': 'Profile 3'}]})
    scopes = ['https://www.googleapis.com/auth/gmail.readonly']
    grant_id = digest_parts('omagma-terminal-grant-v1', *scopes)
    private_json(grants, {'version': 1, 'accounts': [{'account': ACCOUNT, 'clientFile': str(clients),
                          'clientId': client_id, 'grantId': grant_id, 'capabilities': ['mail-read'], 'scopes': scopes}]})
    private_json(preferences, {'schema': 1, 'density': 'compact', 'searchHistory': [
        {'account': ACCOUNT, 'query': 'subject:SyntheticMigrationSearch', 'mode': 'cache'}]})
    account_tokens = credentials / digest_parts('omagma-credential-account-v1', ACCOUNT)
    account_tokens.mkdir(mode=0o700)
    for namespace, grant in (('bar', 'gmail.readonly'), ('terminal', grant_id)):
        name = namespace + '-' + digest_parts('omagma-credential-value-v1', namespace, ACCOUNT, client_id, grant) + '.token'
        token = account_tokens / name
        token.write_bytes(('SyntheticMigrationRefreshToken-' + namespace).encode())
        token.chmod(0o600)

    def legacy(command, **fields):
        raw = dict(id='source-fixture', cmd=command, account=ACCOUNT, **fields)
        result = subprocess.run([str(binary), 'cli', '--fixtures', '--config', str(config), '--cache-dir', str(cache)],
                                input=json.dumps(raw).encode() + b'\n', capture_output=True, env=env, timeout=30)
        require(result.returncode == 0, 'legacy fixture command exited')
        value = json.loads(result.stdout)
        require(value['ok'], f'legacy fixture {command} refused: {value}')
        return value['data']

    mail = legacy('mail.refresh', label='INBOX', limit=3, prefetchLimit=3)['messages']
    legacy('reminder.set', messageId=mail[0]['id'], dueDate='2027-01-01', expectedVersion=0)
    attached = source / 'attachment.txt'
    attached.write_bytes(b'SyntheticMigrationAttachmentOnly\n')
    attached.chmod(0o600)
    attachment = legacy('attachment.import', path=str(attached), mimeType='text/plain')
    draft = legacy('draft.create', draft={'to': 'peer@example.test', 'subject': 'SyntheticMigrationDraft',
                                         'bodyText': 'SyntheticMigrationBody', 'attachments': [attachment]})
    queued = legacy('draft.queue', draftId=draft['id'], operationId='migrated-intent', delaySeconds=0)
    baseline = {p.relative_to(source): hashlib.sha256(p.read_bytes()).digest() for p in source.rglob('*') if p.is_file()}
    source_args = ['--source-config', str(config), '--source-grants', str(grants), '--source-cache', str(cache), '--source-ui', str(preferences)]
    result = subprocess.run([str(binary), 'vault', 'inventory', '--fixtures', *source_args], env=env,
                            capture_output=True, timeout=30)
    require(result.returncode == 0, 'read-only inventory failed: ' + result.stderr.decode())
    inventory = json.loads(result.stdout)['data']
    require(not inventory['credentialsRead'] and inventory['objects'] >= 5, 'inventory skipped source records or read credentials')
    require({p.relative_to(source): hashlib.sha256(p.read_bytes()).digest() for p in source.rglob('*') if p.is_file()} == baseline,
            'dry-run inventory mutated source files')
    vault = root / 'vault'
    socket = root / 'ipc' / 'socket'
    migrate = ['vault', 'migrate', '--fixtures', '--vault-dir', str(vault), *source_args]

    def preflight_refuses(args, expected):
        result = subprocess.run([str(binary), *args], env=env, capture_output=True, timeout=30)
        require(result.returncode != 0 and expected.encode() in result.stderr,
                'preflight did not report ' + expected)
        require(b'New vault password:' not in result.stderr and not vault.exists(),
                'invalid source reached password prompt or destination publication')

    wrong_cache = source_args.copy()
    wrong_cache[wrong_cache.index('--source-cache') + 1] = str(source)
    preflight_refuses(['vault', 'migrate', '--fixtures', '--vault-dir', str(vault), *wrong_cache],
                     'VaultMigrationCacheRequired')
    empty = subprocess.run([str(binary), 'vault', 'inventory', '--fixtures', '--allow-empty-cache', *wrong_cache],
                           env=env, capture_output=True, check=True, timeout=30)
    require(not json.loads(empty.stdout)['data']['accounts'][0]['present'],
            'explicit empty-cache inventory was not reported as absent')
    clients.chmod(0o644)
    try:
        preflight_refuses(['vault', 'inventory', '--fixtures', *source_args], 'UnsafeCredentialPermissions')
        preflight_refuses(migrate, 'UnsafeCredentialPermissions')
    finally:
        clients.chmod(0o600)
    grants_saved = grants.read_bytes()
    grants.unlink()
    try:
        preflight_refuses(migrate, 'VaultMigrationGrantsRequired')
    finally:
        grants.write_bytes(grants_saved)
        grants.chmod(0o600)
    terminal_token = next(account_tokens.glob('terminal-*.token'))
    held_token = root / 'synthetic-token-held-for-preflight'
    terminal_token.rename(held_token)
    try:
        preflight_refuses(migrate, 'VaultMigrationTokenRequired')
    finally:
        held_token.rename(terminal_token)

    def password_with_source_lease_check(_capture):
        raw = dict(id='migration-source-writer', cmd='queue.process', account=ACCOUNT,
                   queueId=queued['queueId'])
        result = subprocess.run([str(binary), 'cli', '--fixtures', '--config', str(config),
                                 '--cache-dir', str(cache)], input=json.dumps(raw).encode() + b'\n',
                                env=env, capture_output=True, timeout=10)
        value = json.loads(result.stdout)
        require(not value['ok'] and value['error']['code'] == 'CacheBusy',
                'source writer was admitted while migration held its preflight leases')
        return PASSWORD

    capture = prompt(binary, [*migrate, '--fixture-stop-after', '0'], env,
                     [(b'New vault password: ', password_with_source_lease_check), (b'Confirm password: ', PASSWORD),
                      (b'Confirm recovery key: ', displayed_recovery)], success=False)
    require(b'VaultMigrationInterrupted' in capture, 'copy did not stop between durable manifest and identity publication')
    capture = b''
    capture = prompt(binary, [*migrate, '--resume', '--fixture-stop-after', '1'], env,
                     [(b'Vault password: ', PASSWORD)], success=False)
    require(b'VaultMigrationInterrupted' in capture, 'resume did not stop at the durable object checkpoint')
    capture = b''
    # A durable header is not permission to serve an incomplete imported set.
    incomplete = subprocess.Popen([str(binary), 'vault', 'serve', '--fixtures', '--vault-dir', str(vault),
                                   '--socket', str(socket)], env=env, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE, start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while not socket.exists() and incomplete.poll() is None and time.monotonic() < deadline:
            time.sleep(.02)
        require(socket.exists(), 'incomplete vault did not start its locked control service')
        refused = prompt(binary, ['vault', 'unlock', '--socket', str(socket)], env,
                         [(b'Vault password: ', PASSWORD)])
        require(b'VaultMigrationIncomplete' in refused, 'incomplete migration became usable')
        status = subprocess.run([str(binary), 'vault', 'status', '--socket', str(socket)], env=env,
                                capture_output=True, check=True, timeout=10)
        require(not json.loads(status.stdout)['data']['unlocked'], 'incomplete owner retained unlocked admission')
    finally:
        subprocess.run([str(binary), 'vault', 'stop', '--socket', str(socket)], env=env,
                       capture_output=True, timeout=10)
        try:
            incomplete.wait(timeout=5)
        except subprocess.TimeoutExpired:
            incomplete.kill()
            incomplete.wait()
        incomplete.stderr.close()
    refused = prompt(binary, ['vault', 'activate', '--fixtures', '--vault-dir', str(vault), '--socket', str(socket)],
                     env, [(b'Vault password: ', PASSWORD)], success=False)
    require(b'VaultMigrationIncomplete' in refused, 'incomplete migration published activation')
    require(not (Path(env['XDG_CONFIG_HOME']) / 'omagma' / 'native-vault.json').exists(),
            'failed activation published a marker')
    source_record = next(cache.rglob('draft-*.json'))
    original = source_record.read_bytes()
    source_record.write_bytes(original + b' ')
    prompt(binary, [*migrate, '--resume'], env, [(b'Vault password: ', PASSWORD)], success=False)
    source_record.write_bytes(original)
    completed = prompt(binary, [*migrate, '--resume'], env, [(b'Vault password: ', PASSWORD)])
    reports = [json.loads(line) for line in completed.splitlines() if line.startswith(b'{"preflight":')]
    require(len(reports) == 1, 'migration omitted its preflight count report')
    report = reports[0]['preflight']
    require(report['credentials'] == 2 and report['accounts'] == inventory['accounts'],
            'migration counts diverged from inventory: ' + json.dumps(report))
    completed = b''
    for relative, digest in baseline.items():
        require(hashlib.sha256((source / relative).read_bytes()).digest() == digest, 'migration changed original source data')
    for file in vault.rglob('*'):
        if file.is_file():
            contents = file.read_bytes()
            require(file.stat().st_mode & 0o077 == 0, 'migration published a nonprivate file')
            for marker in (ACCOUNT.encode(), b'SyntheticMigrationBody', b'SyntheticMigrationRefreshToken',
                           b'SyntheticClientSecretOnly', b'SyntheticMigrationSearch', PASSWORD):
                require(marker not in contents, 'migration leaked known plaintext')
    # Activation must reject a changed available source, including queue state.
    index_file = next(cache.rglob('index.json'))
    saved_account = root / 'source-account-before-legacy-send'
    shutil.copytree(index_file.parent, saved_account)
    activation_args = ['vault', 'activate', '--fixtures', '--vault-dir', str(vault) + '/', '--socket', str(socket)]
    try:
        require(legacy('queue.process', queueId=queued['queueId'])['state'] == 'applied',
                'legacy synthetic send did not produce an outcome')
        refused = prompt(binary, activation_args, env, [(b'Vault password: ', PASSWORD)], success=False)
        require(b'VaultMigrationSourceChanged' in refused, 'activation ignored a source send after migration')
    finally:
        shutil.rmtree(index_file.parent)
        shutil.copytree(saved_account, index_file.parent)
        shutil.rmtree(saved_account)
    hidden_preflight = root / 'source-unavailable-before-activation'
    source.rename(hidden_preflight)
    try:
        refused = prompt(binary, activation_args, env, [(b'Vault password: ', PASSWORD)], success=False)
        require(b'VaultMigrationSourceUnavailable' in refused, 'activation silently claimed unavailable source freshness')
    finally:
        hidden_preflight.rename(source)
    require(not (Path(env['XDG_CONFIG_HOME']) / 'omagma' / 'native-vault.json').exists(),
            'failed source freshness published activation')
    # A plaintext JSONL session created before activation must also refuse
    # its next command after the marker appears; it cannot keep using source.
    preexisting = subprocess.Popen([str(binary), 'cli', '--config', str(config), '--grant-file', str(grants),
                                   '--cache-dir', str(cache)], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def old_session_request():
        preexisting.stdin.write(json.dumps(dict(id='preexisting-session', cmd='auth.status', account=ACCOUNT)).encode() + b'\n')
        preexisting.stdin.flush()
        ready, _, _ = select.select([preexisting.stdout], [], [], 10)
        require(ready, 'preexisting session did not return a bounded response')
        return json.loads(preexisting.stdout.readline())

    marker = Path(env['XDG_CONFIG_HOME']) / 'omagma' / 'native-vault.json'
    try:
        require(old_session_request()['ok'], 'preexisting synthetic session failed before activation')
        prompt(binary, activation_args, env, [(b'Vault password: ', PASSWORD)])
        require(marker.exists(), 'explicit activation did not publish its private marker')
        refused = old_session_request()
        require(not refused['ok'] and refused['error']['code'] == 'BackendRequired',
                'preexisting plaintext session bypassed activation')
        marker_bytes = marker.read_bytes()
        try:
            marker.write_bytes(b'{broken')
            refused = old_session_request()
            require(not refused['ok'], 'preexisting session ignored an invalid activation marker')
        finally:
            marker.write_bytes(marker_bytes)
    finally:
        preexisting.stdin.close()
        try:
            preexisting.wait(timeout=5)
        except subprocess.TimeoutExpired:
            preexisting.kill()
            preexisting.wait()
        preexisting.stdout.close()
        preexisting.stderr.close()

    def control(verb):
        result = evidence.process('control-' + verb, [str(binary), 'vault', verb, '--socket', str(socket)],
                                  env=env, capture_output=True, timeout=20)
        require(result.returncode == 0, 'control failed: ' + command_result(result))
        value = json.loads(result.stdout)
        require(value['ok'], f'control {verb} refused')
        return value['data']

    def start(fixtures=True):
        result = evidence.process('explicit-start',
                                  [str(binary), 'vault', 'start', *(['--fixtures'] if fixtures else []), '--vault-dir', str(vault), '--socket', str(socket)],
                                  env=env, capture_output=True, timeout=20)
        require(result.returncode == 0, 'native detached start failed: ' + command_result(result))

    def remote(command, **fields):
        result = subprocess.run([str(binary), 'cli'], env=env, capture_output=True, timeout=30,
                                input=json.dumps(dict(id='activated-migration', cmd=command, account=ACCOUNT, **fields)).encode() + b'\n')
        require(result.returncode == 0, 'activated CLI failed: ' + result.stderr.decode())
        value = json.loads(result.stdout)
        require(value['ok'], f'activated {command} refused: {value}')
        return value['data']

    def unlock():
        prompt(binary, ['vault', 'unlock', '--socket', str(socket)], env, [(b'Vault password: ', PASSWORD)])
        require(control('status')['unlocked'], 'migrated vault did not unlock')

    started = False
    try:
        started = True
        start()
        start()  # Matching owner makes repeated start idempotent.
        require(not control('status')['unlocked'], 'detached service retained local migration key')
        unlock()
        require(remote('draft.read', draftId=draft['id'])['bodyText'] == 'SyntheticMigrationBody', 'draft ID/body did not survive')
        require(remote('auth.status')['configured'], 'sealed grant/client binding did not survive')
        require(remote('preferences.get')['preferences']['searchHistory'][0]['query'] == 'subject:SyntheticMigrationSearch',
                'global preferences did not migrate')
        require(remote('reminder.list')['entries'][0]['messageId'] == mail[0]['id'], 'follow-up did not migrate')
        paused = remote('queue.process', queueId=queued['queueId'], wait=True)
        require(paused['state'] == 'queued' and paused['resumeRequired'], 'imported due send ran automatically')
        require(remote('cache.stats')['fixtureSends'] == 0, 'migration replayed a send')
        remote('queue.resume', queueId=queued['queueId'], delaySeconds=0)
        require(remote('queue.process', queueId=queued['queueId'])['state'] == 'applied', 'explicit resume did not send once')
        require(remote('cache.stats')['fixtureSends'] == 1, 'explicit resumed send count changed')
        control('stop')
        started = False
        wait_stopped(socket)
        started = True
        start()
        require(not control('status')['unlocked'], 'restarted service retained unlocked key')
        unlock()
        require(remote('cache.stats')['fixtureSends'] == 1, 'restart replayed migrated intent')
        control('stop')
        started = False
        wait_stopped(socket)
        # Qualify the nonfixture read-only identity/cache routing with wholly
        # synthetic state and unavailable original paths. No provider request
        # or mutation is made in this phase.
        hidden_source = root / 'retained-source-unavailable'
        source.rename(hidden_source)
        try:
            started = True
            result = evidence.process('marker-start', [str(binary), 'vault', 'start'],
                                      env=env, capture_output=True, timeout=20)
            require(result.returncode == 0, 'activation marker did not supply default vault/socket for start: ' + command_result(result))
            status = evidence.process('marker-status', [str(binary), 'vault', 'status'],
                                      env=env, capture_output=True, timeout=10)
            require(status.returncode == 0, 'marker-routed status failed: ' + command_result(status))
            require(not json.loads(status.stdout)['data']['unlocked'], 'marker-routed status missed locked owner')
            prompt(binary, ['vault', 'unlock'], env, [(b'Vault password: ', PASSWORD)])
            require(control('status')['unlocked'], 'marker-routed unlock missed owner')
            authenticated = remote('auth.status')
            require(authenticated['configured'] and authenticated['credentialStore'] == 'vault'
                    and authenticated['grant']['grantId'] == grant_id,
                    'nonfixture identity path did not use the sealed grant')
            require(remote('draft.read', draftId=draft['id'])['bodyText'] == 'SyntheticMigrationBody',
                    'nonfixture cache path did not use the sealed draft')
        finally:
            hidden_source.rename(source)
    finally:
        failure = sys.exc_info()[1]
        try:
            cleanup_detached(binary, env, socket, started, evidence)
        except BaseException as cleanup_error:
            evidence.value['cleanupIncomplete'] = True
            evidence.save()
            if failure is None:
                raise
            failure.add_note('Owned daemon cleanup also failed: ' + repr(cleanup_error))
    # Reject unsafe discovery paths before launching a child.
    unsafe = root / 'unsafe-socket-parent'
    unsafe.mkdir(mode=0o755)
    began = time.monotonic()
    failed = subprocess.run([str(binary), 'vault', 'start', '--vault-dir', str(vault), '--socket', str(unsafe / 'socket')],
                            env=env, capture_output=True, timeout=20)
    require(failed.returncode != 0 and b'UnsafeCredentialPermissions' in failed.stderr
            and time.monotonic() - began < 5,
            f'unsafe startup path was not rejected promptly: exit={failed.returncode}, stderr={failed.stderr!r}')
    # Exec success is insufficient when the child fails before socket bind.
    # The client cannot see this held listener lease, so it launches the owner;
    # the owner must exit and its parent must notice without a ten-second wait.
    occupied = root / 'occupied-socket-parent'
    occupied.mkdir(mode=0o700)
    lease = occupied / 'daemon.lock'
    with lease.open('xb') as held:
        lease.chmod(0o600)
        fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        began = time.monotonic()
        failed = subprocess.run([str(binary), 'vault', 'start', '--vault-dir', str(vault),
                                 '--socket', str(occupied / 'socket')],
                                env=env, capture_output=True, timeout=20)
        require(failed.returncode != 0 and b'BackendStartFailed' in failed.stderr
                and time.monotonic() - began < 5,
                f'detached startup missed exited owner: exit={failed.returncode}, stderr={failed.stderr!r}')
    # The real (nonfixture) migration path receives wholly synthetic live files.
    # It performs no provider requests; all credentials are synthetic file values.
    live_cache = source / 'live-cache'
    live_cache.mkdir(mode=0o700)
    shutil.copytree(cache / 'fixtures', live_cache / 'live')
    live_source = source_args.copy()
    live_source[live_source.index('--source-cache') + 1] = str(live_cache)
    live_vault = root / 'live-vault'
    live_socket = root / 'live-ipc' / 'socket'
    live_env = dict(env, XDG_CONFIG_HOME=str(root / 'live-config'))
    Path(live_env['XDG_CONFIG_HOME']).mkdir(mode=0o700)
    result = subprocess.run([str(binary), 'vault', 'inventory', *live_source], env=live_env,
                            capture_output=True, check=True, timeout=30)
    require(json.loads(result.stdout)['data']['accounts'][0]['queued'] == 1,
            'live namespace inventory lost queued source')
    completed = prompt(binary, ['vault', 'migrate', '--vault-dir', str(live_vault), *live_source], live_env,
                       [(b'New vault password: ', PASSWORD), (b'Confirm password: ', PASSWORD),
                        (b'Confirm recovery key: ', displayed_recovery)])
    require(b'"verified":true' in completed, 'nonfixture migration did not verify')
    completed = b''
    hidden_source = root / 'retained-live-source'
    source.rename(hidden_source)
    live_started = False
    try:
        activated = prompt(binary, ['vault', 'activate', '--vault-dir', str(live_vault), '--socket', str(live_socket),
                                   '--allow-unavailable-source'], live_env, [(b'Vault password: ', PASSWORD)])
        require(b'unavailable-acknowledged' in activated, 'explicit source acknowledgement was not reported')
        live_started = True
        result = evidence.process('live-marker-start', [str(binary), 'vault', 'start'],
                                  env=live_env, capture_output=True, timeout=20)
        require(result.returncode == 0, 'live activation marker start failed: ' + command_result(result))
        prompt(binary, ['vault', 'unlock'], live_env, [(b'Vault password: ', PASSWORD)])
        result = subprocess.run([str(binary), 'cli'], env=live_env, capture_output=True, check=True, timeout=20,
                                input=json.dumps(dict(id='real-migration-path', cmd='draft.read', account=ACCOUNT,
                                                      draftId=draft['id'])).encode() + b'\n')
        require(json.loads(result.stdout)['data']['bodyText'] == 'SyntheticMigrationBody',
                'nonfixture migration did not preserve source draft')
    finally:
        failure = sys.exc_info()[1]
        try:
            cleanup_detached(binary, live_env, live_socket, live_started, evidence)
        except BaseException as cleanup_error:
            evidence.value['cleanupIncomplete'] = True
            evidence.save()
            if failure is None:
                raise
            failure.add_note('Owned live daemon cleanup also failed: ' + repr(cleanup_error))
        finally:
            if hidden_source.exists():
                hidden_source.rename(source)
    print('PASS synthetic migration: inventory, checkpoint/resume, incomplete gate, retained source, sealed identity/mail/blob/UI, explicit activation/start, paused sends and restart', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    info = subprocess.run([str(binary), 'build-info'], check=True, capture_output=True, text=True)
    print(info.stdout.strip(), flush=True)
    if args.receipt is not None and args.receipt.exists():
        parser.error('refusing to overwrite a migration receipt')
    evidence = Evidence(args.receipt, json.loads(info.stdout))
    # Darwin's default per-user temporary path can exceed sockaddr_un before
    # the socket permission/child-exit cases reach their intended boundary.
    root = Path(tempfile.mkdtemp(prefix='omagma-vault-migration-', dir=str(Path('/tmp').resolve()))).resolve()
    try:
        try:
            run(binary, root, evidence)
        finally:
            if evidence.value.get('cleanupIncomplete'):
                # Keep an owned fixture tree if its daemon could not be stopped;
                # recursive removal must not race a live writer or hide the cause.
                evidence.value['retainedFixtureRoot'] = str(root)
            else:
                shutil.rmtree(root)
        evidence.value['passed'] = True
    except BaseException:
        evidence.value['failure'] = traceback.format_exc()
        raise
    finally:
        evidence.save()
