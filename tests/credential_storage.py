#!/usr/bin/env python3
"""Real CLI file-storage selection/migration with synthetic private values only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ACCOUNTS = ("one@example.test", "two@example.test", "three@example.test")
TOKENS = ("literal-first-private-value", "a-different-second-value", "third-account-only-value")
CLIENT = "fixture-client.apps.googleusercontent.com"
SCOPES = ("https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.send")
GRANT = hashlib.sha256(b"omagma-terminal-grant-v1\0" + b"".join(s.encode() + b"\0" for s in SCOPES)).hexdigest()

def write_json(path, data):
    path.write_text(json.dumps(data))
    path.chmod(0o600)

def slot(root, account, client=CLIENT, grant=GRANT):
    # Literal storage contract, independently producing input to the real CLI.
    directory = hashlib.sha256(b"omagma-credential-account-v1\0" + account.encode() + b"\0").hexdigest()
    filename = hashlib.sha256(b"omagma-credential-value-v1\0terminal\0" + account.encode() + b"\0" + client.encode() + b"\0" + grant.encode() + b"\0").hexdigest()
    return root / directory / ("terminal-" + filename + ".token")

def seed(root, account, value):
    target = slot(root, account)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    target.parent.chmod(0o700)
    target.write_text(value)
    target.chmod(0o600)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-file-credentials-") as temporary:
        root = Path(temporary).resolve()
        root.chmod(0o700)
        config = root / "config.json"
        grants = root / "grants.json"
        client = root / "client.json"
        source = root / "source"
        destination = root / "destination"
        env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"))
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        def command(*arguments, ok=True):
            p = subprocess.run([str(binary), *arguments], env=env, capture_output=True, text=True, timeout=15)
            assert (p.returncode == 0) == ok, (arguments, p.stdout, p.stderr)
            assert all(value not in p.stdout and value not in p.stderr for value in TOKENS), "credential value escaped into CLI output"
            return json.loads(p.stdout) if ok else p
        accounts = [{"address": a, "profile": "Profile " + str(i + 1)} for i, a in enumerate(ACCOUNTS)]
        write_json(config, {"accounts": accounts})
        status = command("credentials", "status", "--config", str(config), "--json")
        assert status["credentialStore"] == "keyring" and not source.exists()
        selected = command("credentials", "migrate", "--config", str(config), "--grant-file", str(grants),
                           "--to", "file", "--directory", str(source), "--json")
        assert selected["credentialStore"] == "file" and selected["copiedCredentials"] == 0
        assert json.loads(config.read_text())["credentialDirectory"] == str(source)
        write_json(client, {"installed": {"client_id": CLIENT, "client_secret": "fixture-client-secret"}})
        records = [{"account": a, "clientFile": str(client), "clientId": CLIENT, "grantId": GRANT,
                    "capabilities": ["mail-read", "mail-send"], "scopes": list(SCOPES)} for a in ACCOUNTS]
        write_json(grants, {"version": 1, "accounts": records})
        for account, value in zip(ACCOUNTS, TOKENS):
            seed(source, account, value)
            status = command("terminal-auth", "status", "--account", account, "--config", str(config),
                             "--grant-file", str(grants), "--cache-dir", str(root / "mail-cache"))
            assert status["ok"] and status["data"]["configured"] and status["data"]["credentialStore"] == "file"
        moved = command("credentials", "migrate", "--config", str(config), "--grant-file", str(grants),
                        "--to", "file", "--directory", str(destination), "--json")
        assert moved["copiedCredentials"] == 3 and moved["sourceCopiesRetained"] and moved["restartRequired"]
        for account, value in zip(ACCOUNTS, TOKENS):
            assert slot(source, account).read_text() == value
            assert slot(destination, account).read_text() == value
            assert slot(destination, account).stat().st_mode & 0o777 == 0o600
        before = config.read_bytes()
        slot(destination, ACCOUNTS[1]).chmod(0o644)
        refused = command("credentials", "migrate", "--config", str(config), "--grant-file", str(grants),
                          "--to", "file", "--directory", str(root / "third"), "--json", ok=False)
        assert "UnsafeCredentialPermissions" in refused.stderr and config.read_bytes() == before
        slot(destination, ACCOUNTS[1]).chmod(0o600)
        revoked = command("terminal-auth", "revoke", "--account", ACCOUNTS[0], "--config", str(config),
                          "--grant-file", str(grants), "--cache-dir", str(root / "mail-cache"))
        assert revoked["ok"] and revoked["data"]["cleared"]
        assert not slot(destination, ACCOUNTS[0]).exists()
        back = command("credentials", "migrate", "--config", str(config), "--grant-file", str(grants),
                       "--to", "file", "--directory", str(source), "--json")
        assert back["copiedCredentials"] == 2 and not slot(source, ACCOUNTS[0]).exists()
        assert slot(source, ACCOUNTS[1]).read_text() == TOKENS[1] and slot(source, ACCOUNTS[2]).read_text() == TOKENS[2]
        unknown = command("credentials", "unknown", ok=False)
        assert "--help" in unknown.stderr
    print("PASS file credentials CLI: explicit default/file selection, three-account isolation, private migration, unsafe source preservation, revoke/switch-back and no secret output")

if __name__ == "__main__":
    main()
