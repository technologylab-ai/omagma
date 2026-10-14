"""Fixture daemon reached through the same activation path as real clients."""
import json
import subprocess

from terminal_integration import require


def run(binary, backend, env, vault, control):
    from pathlib import Path
    folder = Path(env['XDG_CONFIG_HOME']) / 'omagma'
    folder.mkdir(mode=0o700, exist_ok=True)
    marker = folder / 'native-vault.json'
    require(not marker.exists(), 'test refuses to replace existing activation')
    identity = control('status')['vaultId']
    value = dict(schema=1, vaultDirectory=str(vault), vaultId=identity, socketPath=str(backend))

    def write():
        marker.write_text(json.dumps(value) + '\n')
        marker.chmod(0o600)

    def command(*extra):
        return subprocess.run([str(binary), 'cli', *extra], env=env,
                              input=b'{"id":"activation-route","cmd":"accounts.list"}\n',
                              capture_output=True, timeout=15)

    try:
        write()
        result = command()
        require(result.returncode == 0, 'automatic vault routing failed: ' + result.stderr.decode())
        response = json.loads(result.stdout)
        require(response['ok'] and len(response['data']['accounts']) == 3, 'automatic route did not use the unlocked fixture owner')
        # No config or grant was installed in this HOME: reading its fixture
        # accounts proves the native client did not fall back to plaintext.
        value['vaultId'] = 'ff' * 16 if identity != 'ff' * 16 else 'ee' * 16
        write()
        result = command()
        response = json.loads(result.stdout)
        require(not response['ok'] and response['error']['code'] == 'VaultIdentityMismatch', 'activation accepted another vault identity')
        value['vaultId'] = identity
        write()
        result = command('--cache-dir', str(folder / 'must-not-exist'))
        require(result.returncode != 0 and b'VaultOptionConflict' in result.stderr, 'activated client accepted competing plaintext cache')
        require(not (folder / 'must-not-exist').exists(), 'conflicting cache option created plaintext files')
        control('lock')
        result = command()
        response = json.loads(result.stdout)
        require(not response['ok'] and response['error']['code'] == 'VaultLocked', 'locked activation silently fell back')
    finally:
        marker.unlink(missing_ok=True)
    print('PASS vault activation routing: expected identity, no plaintext fallback, conflicting paths refused', flush=True)
