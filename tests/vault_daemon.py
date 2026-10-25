#!/usr/bin/env python3
"""Synthetic vault process/owned-PTY acceptance. Requires the host test lease."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

import vault_tui_exit
import vault_activation_routing

PASSWORD = b"Synthetic vault acceptance password"
ACCOUNT = "personal@example.com"
MAGIC = b"OMAVIPC1"
EXECUTION_MAGIC = b"OMAVIPC2"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def prompt(binary, arguments, env, prompts, success=True):
    """Only our child owns this PTY; no desktop window or user input is used."""
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execve(str(binary), [str(binary), *arguments], env)
    capture = bytearray()
    next_prompt = 0
    status = None
    deadline = time.monotonic() + 25
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([descriptor], [], [], .05)
            if ready:
                try:
                    part = os.read(descriptor, 65536)
                except OSError:
                    part = b""
                if part:
                    capture.extend(part)
                    if next_prompt < len(prompts) and prompts[next_prompt][0] in capture:
                        answer = prompts[next_prompt][1]
                        if callable(answer):
                            answer = answer(bytes(capture))
                        os.write(descriptor, answer + b"\n")
                        next_prompt += 1
            ended, result = os.waitpid(pid, os.WNOHANG)
            if ended:
                status = result
                # Exit can race the final PTY write. Drain only this owned
                # child's ready bytes before checking its structured result.
                while select.select([descriptor], [], [], 0)[0]:
                    try:
                        tail = os.read(descriptor, 65536)
                    except OSError:
                        break
                    if not tail:
                        break
                    capture.extend(tail)
                break
        require(status is not None, "private password prompt timed out")
        exit_code = os.waitstatus_to_exitcode(status)
        safe_errors = [value.decode("ascii") for value in re.findall(rb"error: ([A-Za-z][A-Za-z0-9_]{0,80})", capture)]
        require((exit_code == 0) == success,
                f"private terminal control returned unexpected exit {exit_code}; error names: {safe_errors}")
        require(next_prompt == len(prompts), "password control skipped a required local prompt")
        require(PASSWORD not in capture, "password was echoed to the terminal")
        return bytes(capture)
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(descriptor)


def displayed_recovery(capture):
    matches = re.findall(rb"Recovery key \(store privately\): (OMR1-(?:[0-9a-f]{8}-){8}[0-9a-f]{8})", capture)
    require(len(matches) == 1, "recovery display did not contain one checked key")
    return matches[0]


def run(binary, directory):
    env = dict(os.environ, HOME=str(directory / "home"), XDG_CONFIG_HOME=str(directory / "config"),
               XDG_CACHE_HOME=str(directory / "cache"))
    env.pop("XDG_RUNTIME_DIR", None)  # Models noninteractive SSH discovery.
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        Path(env[key]).mkdir(mode=0o700)
    vault = directory / "vault"
    ipc = directory / "ipc"
    backend = ipc / "socket"
    canceled_vault = directory / "canceled-vault"
    prompt(binary, ["vault", "init", "--fixtures", "--vault-dir", str(canceled_vault)], env,
           [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
            (b"Confirm recovery key: ", b"\x03")], success=False)
    require(not canceled_vault.exists(), "canceled recovery confirmation published vault files")
    capture = prompt(binary, ["vault", "init", "--fixtures", "--vault-dir", str(vault)], env,
                     [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
                      (b"Confirm recovery key: ", displayed_recovery)])
    require(b"Recovery key (store privately): " in capture, "creation did not expose local recovery material")
    initial_recovery = displayed_recovery(capture)
    capture = b""  # Never persist the recovery-key terminal capture.
    daemon = None

    def start():
        child = subprocess.Popen([str(binary), "vault", "serve", "--fixtures", "--vault-dir", str(vault),
                                  "--socket", str(backend)], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise AssertionError("fixture daemon exited: " + child.stderr.read().decode())
            if backend.exists():
                return child
            time.sleep(.02)
        child.kill()
        child.wait()
        raise AssertionError("fixture daemon did not bind its private socket")

    def control(verb):
        result = subprocess.run([str(binary), "vault", verb, "--socket", str(backend)], env=env,
                                capture_output=True, timeout=15)
        require(result.returncode == 0, f"control {verb} failed: {result.stderr.decode()}")
        value = json.loads(result.stdout)
        require(value["ok"], f"control {verb} refused: {value}")
        return value["data"]

    serial = 0

    def request(command, account=ACCOUNT, ok=True, **fields):
        nonlocal serial
        serial += 1
        value = dict(id=f"vault-fixture-{serial}", cmd=command, account=account, **fields)
        result = subprocess.run([str(binary), "cli", "--backend", str(backend)],
                                input=json.dumps(value).encode() + b"\n", capture_output=True,
                                env=env, timeout=45)
        require(bool(result.stdout.strip()), f"missing {command} response: {result.stderr.decode()}")
        response = json.loads(result.stdout)
        require(response.get("id") == value["id"] and response.get("account") == account,
                f"{command} lost request correlation")
        if ok is None:
            return response
        require(response["ok"] == ok, f"{command} unexpected response: {response}")
        return response["data"] if ok else response["error"]

    def unlock():
        prompt(binary, ["vault", "unlock", "--socket", str(backend)], env,
               [(b"Vault password: ", PASSWORD)])
        require(control("status")["unlocked"], "password did not unlock the owned service")

    try:
        daemon = start()
        require(not control("status")["unlocked"], "service restart did not begin locked")
        malformed_frames(backend, control)
        require(request("accounts.list", ok=False)["code"] == "VaultLocked", "locked daemon served account data")
        canceled_prompt(binary, backend, env)
        unlock()
        # Admission has completed when the fixture enters its timed refresh;
        # lock must cancel the owner job, join it, then erase the key promptly.
        delayed = subprocess.Popen([str(binary), "cli", "--backend", str(backend)], env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        delayed.stdin.write(json.dumps(dict(id="cancel-active-read", cmd="mail.refresh", account=ACCOUNT,
                                            fixtureDelayMs=30000)).encode() + b"\n")
        delayed.stdin.close()
        time.sleep(.2)
        require(request("preferences.get", account="", ok=False)["code"] == "VaultBusy",
                "fixture refresh did not establish owner admission")
        before_lock = time.monotonic()
        control("lock")
        require(time.monotonic() - before_lock < 4, "lock did not interrupt the active owner operation")
        require(delayed.wait(timeout=5) == 0, "interrupted relay failed without a structured response")
        canceled = json.loads(delayed.stdout.read())
        require(canceled["id"] == "cancel-active-read" and not canceled["ok"], "interrupted read lost correlation")
        require(canceled["error"]["code"] == "UnknownOutcome",
                "admitted cache refresh did not retain conservative interruption classification: " + canceled["error"]["code"])
        unlock()
        require(len(request("accounts.list")["accounts"]) == 3, "fixture account catalog changed")
        require(request("preferences.get", account="")["preferences"] is None, "new vault has stale UI preferences")
        preference_accounts = (ACCOUNT, "work@example.com", "optional@example.com")
        ui_preferences = {"density": "compact", "savedSearches": [], "searchHistory": []}
        for index in range(24):
            query = "subject:Sealed-preferences-marker" if index == 0 else f"subject:synthetic-{index}-" + "x" * 4000
            ui_preferences["savedSearches"].append(dict(account=preference_accounts[index // 8], name=f"Private search {index}", query=query, mode="cache"))
            ui_preferences["searchHistory"].append(dict(account=preference_accounts[index // 8], query=query, mode="cache"))
        require(len(json.dumps(ui_preferences)) > 128 * 1024, "preference fixture no longer proves the full existing capacity")
        require(request("preferences.set", account="", preferences=ui_preferences)["saved"], "preferences were not sealed")
        require(request("preferences.get", account="")["preferences"]["density"] == "compact", "sealed preferences changed")
        require(request("preferences.set", account="", ok=False, preferences={"padding": "x" * (256 * 1024 + 1)})["code"] == "UiPreferencesTooLarge",
                "oversize UI preferences were accepted")
        page = request("mail.refresh", label="INBOX", limit=3, prefetchLimit=3)
        ids = [entry["id"] for entry in page["messages"]]
        require(ids, "sealed fixture refresh returned no mail")
        read = request("mail.read", messageId=ids[0], cacheOnly=True)
        require(read["bodyText"], "sealed body did not read back")
        batch = request("mail.batch", messageIds=ids[:2], action="archive")
        require(batch["appliedCount"] == min(2, len(ids)), "batch bypassed sealed persistence")
        require(request("mail.undo", undoToken=batch["undoToken"])["restoredCount"] == min(2, len(ids)),
                "sealed undo receipt did not persist")
        attachment_file = directory / "synthetic.txt"
        attachment_file.write_bytes(b"Synthetic attached secret for vault process acceptance\n")
        attachment_file.chmod(0o600)
        attachment = request("attachment.import", path=str(attachment_file), mimeType="text/plain")
        draft = request("draft.create", draft={"to": "recipient@example.test", "subject": "Sealed process draft",
                                                "bodyText": "Synthetic draft private body", "attachments": [attachment]})
        reread = request("draft.read", draftId=draft["id"])
        require(reread["attachments"][0]["blobId"] == attachment["blobId"], "sealed draft lost blob ownership")
        sent = request("draft.send", draftId=draft["id"], operationId="synthetic-vault-send-1")
        require(bool(sent), "fixture send did not return its durable receipt")
        require(request("cache.stats")["fixtureSends"] == 1, "fixture send was dropped or duplicated")
        large_body = "Encrypted restart marker" + "x" * (2 * 1024 * 1024 - 24)
        pending = request("draft.create", draft={"subject": "Restart proof", "bodyText": large_body})
        calendars = request("calendar.list")
        require(len(calendars["calendars"]) == 3, "Calendar fixture lost sealed provider ownership")
        agenda = request("calendar.agenda", calendarId=ACCOUNT, date=datetime.now(timezone.utc).date().isoformat())
        require(agenda["snapshot"]["complete"], "Calendar encrypted snapshot is incomplete")
        # A client that does not consume a large response cannot keep the key
        # alive indefinitely. Control retains its second bounded worker.
        with socket.socket(socket.AF_UNIX) as stalled_response:
            stalled_response.settimeout(2)
            stalled_response.connect(str(backend))
            frame = json.dumps(dict(id="stalled-response", cmd="draft.read", account=ACCOUNT, draftId=pending["id"])).encode()
            stalled_response.sendall(EXECUTION_MAGIC + bytes([1, 0, 0, 0]) + struct.pack("<I", len(frame)) + frame)
            time.sleep(.1)
            require(control("status")["unlocked"], "stalled response blocked control")
            before_lock = time.monotonic()
            control("lock")
            require(time.monotonic() - before_lock < 8, "lock failed to drain a stalled response within its deadline")
        require(request("draft.read", draftId=pending["id"], ok=False)["code"] == "VaultLocked", "lock exposed draft")
        unlock()
        require(request("draft.read", draftId=pending["id"])["bodyText"] == large_body, "relock lost maximum-size draft")
        control("stop")
        require(daemon.wait(timeout=10) == 0, "fixture service stop failed")
        require(not backend.exists(), "stopped service left a live socket")
        daemon = start()
        require(not control("status")["unlocked"], "new service retained a previous key")
        unlock()
        require(request("draft.read", draftId=pending["id"])["bodyText"] == large_body, "restart lost maximum-size draft")
        require(request("cache.stats")["fixtureSends"] == 1, "restart replayed fixture send")
        require(request("preferences.get", account="")["preferences"]["savedSearches"][0]["query"] == "subject:Sealed-preferences-marker",
                "restart lost sealed search preferences")
        vault_tui_exit.run(binary, directory, backend, env, request)
        vault_activation_routing.run(binary, backend, env, vault, control)
        unlock()
        if sys.platform.startswith("linux"):
            import vault_resources
            vault_resources.run(binary, directory, backend, env, daemon.pid)
        else:
            print("SKIP Linux /proc RSS/PSS measurement; native memory qualification is separate", flush=True)
        replacement_password = b"Synthetic rotated vault password"
        capture = prompt(binary, ["vault", "password", "--socket", str(backend)], env,
                         [(b"New vault password: ", replacement_password), (b"Confirm password: ", replacement_password)])
        require(replacement_password not in capture, "replacement password echoed")
        control("lock")
        capture = prompt(binary, ["vault", "unlock", "--socket", str(backend)], env,
                         [(b"Vault password: ", PASSWORD)])
        require(b"VaultAuthenticationFailed" in capture and not control("status")["unlocked"], "old password remained usable")
        prompt(binary, ["vault", "unlock", "--socket", str(backend)], env,
               [(b"Vault password: ", replacement_password)])
        capture = prompt(binary, ["vault", "recovery-key", "--socket", str(backend)], env,
                         [(b"Confirm recovery key: ", displayed_recovery)])
        replacement_recovery = displayed_recovery(capture)
        capture = b""
        control("lock")
        capture = prompt(binary, ["vault", "recover", "--socket", str(backend)], env,
                         [(b"Recovery key: ", initial_recovery), (b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD)])
        require(b"VaultAuthenticationFailed" in capture and not control("status")["unlocked"], "retired recovery key remained usable")
        prompt(binary, ["vault", "recover", "--socket", str(backend)], env,
               [(b"Recovery key: ", replacement_recovery), (b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD)])
        initial_recovery = replacement_recovery = capture = b""
        require(control("status")["unlocked"], "recovery failed to authenticate and reset the password")
        control("lock")
        unlock()
        for file in vault.rglob("*"):
            if file.is_file():
                require(file.stat().st_mode & 0o077 == 0, "vault file escaped owner-only permissions")
                stored = file.read_bytes()
                for marker in (PASSWORD, b"Synthetic draft private body", b"Encrypted restart marker",
                               b"Synthetic attached secret", b"Sealed-preferences-marker", ACCOUNT.encode()):
                    require(marker not in stored, "vault file contains known plaintext")
        require(not list((directory / "cache").rglob("index.json")), "vault path created a plaintext cache")
        daemon.terminate()
        require(daemon.wait(timeout=10) == 0, "SIGTERM did not drain/wipe the fixture service")
        require(not backend.exists(), "SIGTERM left the owned socket behind")
        daemon = None
    finally:
        if daemon is not None:
            if daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()
            if daemon.returncode != 0:
                print(f"fixture daemon exit={daemon.returncode}: {daemon.stderr.read().decode(errors='replace')}", file=sys.stderr)
    print("PASS vault owned-PTY init/unlock, encrypted mail/draft/blob/send/Calendar/batch, lock and restart")
    protocol_generation(binary, directory, env)
    disconnects(binary, directory, env)
    import vault_conversation_paths
    vault_conversation_paths.run(binary, directory, env)
    import vault_foreground_priority
    vault_foreground_priority.run(binary, directory, env)


def malformed_frames(backend, control):
    # Native compose records allow escaped source alternatives up to 12x35MiB.
    # The former 3MiB+1 header is valid; without a body it must hit the arrival
    # deadline, not the immediate malformed-header rejection below.
    native_execute_limit = 12 * 35 * 1024 * 1024

    def header(kind, length, magic=None, reserved=b"\0\0\0"):
        magic = magic or (EXECUTION_MAGIC if kind in (1, 2, 6, 7, 8) else MAGIC)
        return magic + bytes([kind]) + reserved + struct.pack("<I", length)

    invalid = (
        ("wrong magic", header(1, 0, magic=b"WRONGIPC")),
        ("wrong version", header(1, 0, magic=b"OMAVIPC3")),
        ("unknown kind", header(127, 0)),
        ("reserved flags", header(1, 0, reserved=b"\1\0\0")),
        ("native execute overflow", header(1, native_execute_limit + 1)),
        ("empty password", header(2, 0)),
        ("oversized password", header(2, 1025)),
        ("nonempty status", header(4, 1)),
        ("short recovery key", header(7, 31)),
    )
    for name, value in invalid:
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(2)
            peer.connect(str(backend))
            peer.sendall(value)
            try:
                closed = peer.recv(1) == b""
            except TimeoutError as failure:
                raise AssertionError(f"invalid {name} frame waited for a body instead of closing") from failure
            require(closed, f"invalid {name} frame was accepted or retained")
    # One partial peer cannot occupy the control connection indefinitely.
    for name, value in (("partial header", MAGIC[:4]),
                        ("largest native body missing", header(1, native_execute_limit)),
                        ("legacy body stalled during metadata", header(1, 1 << 20, magic=MAGIC) + b'{"draft":{"bodyText":"'),
                        ("legacy malformed body stalled during drain", header(1, 1 << 20, magic=MAGIC) + b'not-json')):
        with socket.socket(socket.AF_UNIX) as stalled:
            stalled.settimeout(7)
            started = time.monotonic()
            stalled.connect(str(backend))
            stalled.sendall(value)
            require(not control("status")["unlocked"], f"{name} blocked status or unlocked the vault")
            require(time.monotonic() - started < 2, f"{name} delayed the independent control connection")
            require(not select.select([stalled], [], [], 0)[0], f"valid {name} was rejected before its arrival deadline")
            stalled.settimeout(max(.01, 7 - (time.monotonic() - started)))
            require(stalled.recv(1) == b"", f"{name} ignored its arrival deadline")
            require(4 <= time.monotonic() - started <= 7, f"{name} changed the five-second arrival deadline")
        reclaimed = time.monotonic()
        require(not control("lock")["unlocked"] and not control("status")["unlocked"],
                f"{name} left a blocked worker or changed lock state")
        require(time.monotonic() - reclaimed < 2, f"{name} did not release its worker for lock/status")
    print("PASS native and legacy IPC header limits, independent status and five-second incomplete-frame cleanup", flush=True)


def canceled_prompt(binary, backend, env):
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execve(str(binary), [str(binary), "vault", "unlock", "--socket", str(backend)], env)
    capture = bytearray()
    status = None
    sent = False
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if select.select([descriptor], [], [], .05)[0]:
                try:
                    capture.extend(os.read(descriptor, 4096))
                except OSError:
                    pass
            if not sent and b"Vault password: " in capture:
                require(not termios.tcgetattr(descriptor)[3] & termios.ECHO, "password prompt left echo enabled")
                os.kill(pid, signal.SIGTERM)
                sent = True
            ended, result = os.waitpid(pid, os.WNOHANG)
            if ended:
                status = result
                break
        require(status is not None and sent, "password prompt did not cancel on SIGTERM")
        require(termios.tcgetattr(descriptor)[3] & termios.ECHO, "canceling password input failed to restore terminal echo")
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(descriptor)


def protocol_generation(binary, directory, env):
    """A real new CLI against a synthetic old peer must submit no data frame."""
    peer_dir = directory / "legacy-protocol-peer"
    peer_dir.mkdir(mode=0o700)
    legacy_env = dict(env)
    for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")):
        selected = peer_dir / name
        selected.mkdir(mode=0o700)
        legacy_env[key] = str(selected)
    path = peer_dir / "s"
    for mode in ("execute", "status", "lock", "stop"):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)
        seen, failures = [], []

        def old_peer():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(5)
                    header = b""
                    while len(header) != 16:
                        part = connection.recv(16 - len(header))
                        require(part, "missing legacy control header")
                        header += part
                    expected = {"execute": 4, "status": 4, "lock": 3, "stop": 5}[mode]
                    require(header == MAGIC + bytes([expected, 0, 0, 0]) + struct.pack("<I", 0),
                            "new client transmitted protected data to the old peer")
                    seen.append(expected)
                    payload = b'{"ok":true,"data":{"unlocked":true}}'
                    connection.sendall(MAGIC + bytes([128, 0, 0, 0]) + struct.pack("<I", len(payload)) + payload)
            except BaseException as failure:
                failures.append(failure)

        thread = threading.Thread(target=old_peer, daemon=True)
        thread.start()
        request = dict(id="legacy-backend", account=ACCOUNT, cmd="draft.send",
                       draftId="unsent", operationId="never-sent", expectedContentDigest="a" * 64)
        try:
            arguments = (["cli", "--backend", str(path)] if mode == "execute"
                         else ["vault", mode, "--socket", str(path)])
            result = subprocess.run([str(binary), *arguments], env=legacy_env,
                                    input=(json.dumps(request) + "\n").encode() if mode == "execute" else b"",
                                    capture_output=True, timeout=10)
            thread.join(timeout=5)
            require(not thread.is_alive() and not failures, f"old peer failed: {failures}")
            require(len(seen) == 1, "old peer received extra requests")
            response = json.loads(result.stdout)
            if mode == "execute":
                require(response["id"] == request["id"] and response["account"] == ACCOUNT,
                        "protocol refusal lost request correlation")
                require(response["ok"] is False and response["error"]["code"] == "BackendProtocolMismatch",
                        "old daemon mismatch became a send or unknown outcome")
                for instruction in ("omagma vault stop", "omagma vault start", "omagma vault unlock"):
                    require(instruction in response["error"]["message"], "protocol refusal omitted upgrade advice")
            else:
                require(result.returncode == 0 and response["ok"] is True,
                        f"legacy {mode} stopped working during upgrade")
        finally:
            listener.close()
            thread.join(timeout=5)
            path.unlink()
    print("PASS explicit --backend old peer refuses before data submission; status/lock/stop remain usable")


def disconnects(binary, directory, env):
    peer_dir = directory / "drop-peer"
    peer_dir.mkdir(mode=0o700)
    path = peer_dir / "s"
    for command, expected in (("mail.read", "BackendStopped"), ("draft.create", "UnknownOutcome"),
                              ("attachment.import", "UnknownOutcome"), ("future.mutation", "UnknownOutcome")):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)
        counts = []

        def drop():
            # Semantic preflight is read-only. Only the subsequent execute
            # counts as an admitted request for the uncertainty oracle.
            connection, _ = listener.accept()
            with connection:
                status = b""
                while len(status) != 16:
                    status += connection.recv(16 - len(status))
                require(status == MAGIC + bytes([4, 0, 0, 0]) + struct.pack("<I", 0), "missing protocol preflight")
                payload = b'{"ok":true,"data":{"executionProtocol":2}}'
                connection.sendall(MAGIC + bytes([128, 0, 0, 0]) + struct.pack("<I", len(payload)) + payload)
            connection, _ = listener.accept()
            with connection:
                header = b""
                while len(header) != 16:
                    header += connection.recv(16 - len(header))
                require(header[:8] == EXECUTION_MAGIC, "client lost protected IPC generation")
                remaining = struct.unpack("<I", header[12:])[0]
                while remaining:
                    part = connection.recv(min(65536, remaining))
                    require(part, "client failed before submitting the request")
                    remaining -= len(part)
                counts.append(1)

        thread = threading.Thread(target=drop, daemon=True)
        thread.start()
        value = dict(id="drop-test", cmd=command, account=ACCOUNT)
        result = subprocess.run([str(binary), "cli", "--backend", str(path)],
                                input=json.dumps(value).encode() + b"\n", capture_output=True, env=env, timeout=10)
        thread.join(timeout=2)
        listener.close()
        path.unlink()
        require(counts == [1], "disconnect caused multiple submissions")
        require(expected.encode() in result.stdout + result.stderr, f"{command} disconnect lost {expected}")
        response = json.loads(result.stdout)
        require(response["id"] == value["id"] and response["account"] == ACCOUNT,
                f"{command} disconnect lost request correlation")
        require(response["ok"] is False and response["error"]["code"] == expected,
                f"{command} disconnect was not a structured failure")
    print("PASS submitted mutation disconnects report UnknownOutcome with no replay; reads report BackendStopped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    version = subprocess.check_output([str(binary), "build-info"], text=True).strip()
    print(f"{version}; platform={os.uname().sysname}-{os.uname().machine}", flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-vault-", dir="/tmp") as temporary:
        run(binary, Path(temporary).resolve())


if __name__ == "__main__":
    main()
