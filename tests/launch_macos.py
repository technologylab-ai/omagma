#!/usr/bin/env python3
"""Native spawn flag/exec handshake regression with a fictional detached child."""
import argparse
import json
import signal
import select
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

from terminal_integration import require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    require(sys.platform == "darwin", "native detached spawn requires Darwin")
    with tempfile.TemporaryDirectory(prefix="omagma-macos-detached-") as temporary:
        root = Path(temporary)
        receipt = root / "receipt.json"
        sentinel = root / "must-not-exist"
        read_fd, write_fd = os.pipe()
        os.set_inheritable(write_fd, True)
        child = None
        spawned_pid = None
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
        old_ttou = signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        try:
            # Independent positive control: this descriptor and mask would leak.
            control = subprocess.run([sys.executable, "-c", "import os,sys,signal;os.fstat(int(sys.argv[1]));assert signal.SIGUSR1 in signal.pthread_sigmask(signal.SIG_BLOCK,[])", str(write_fd)], close_fds=False, capture_output=True, timeout=8)
            require(control.returncode == 0, "inherited descriptor/mask positive control failed")
            child = subprocess.Popen([str(args.binary.resolve()), "__launch-worker", sys.executable,
                str(Path(__file__).parent / "fixtures/terminal/launch_macos_fixture.py"), str(receipt), str(write_fd),
                "--profile-directory=Profile Fictional", f"literal $(touch {sentinel})"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=False)
            require(select.select([child.stdout], [], [], 5)[0], "native PID handshake timed out")
            out = os.read(child.stdout.fileno(), 4)
            child.stdin.write(b"\x01"); child.stdin.close(); child.stdin = None
            trailing, error = child.communicate(timeout=8)
            out += trailing
            require(child.returncode == 0 and not error and len(out) == 4, "native intermediary did not report one PID/clean exec")
            spawned_pid = struct.unpack("=i", out)[0]
            deadline = time.monotonic() + 5
            while not receipt.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            require(receipt.exists(), "native detached witness did not finish")
            value = json.loads(receipt.read_text())
            require(value["pid"] == spawned_pid and value["session"] == spawned_pid and value["group"] == spawned_pid,
                    "native SETSID did not create an independent session/group")
            require(value["inheritedSentinel"] is False, "native CLOEXEC_DEFAULT leaked an unrelated descriptor")
            require(value["stdinEof"] and not value["stdoutIsTty"] and not value["stderrIsTty"], "detached child retained the owned terminal")
            require(value["argv"] == ["--profile-directory=Profile Fictional", f"literal $(touch {sentinel})"] and not sentinel.exists(),
                    "native launch rewrote profile/arguments or evaluated a shell")
            require(value["blockedSignals"] == [], "native child inherited blocked runtime signals")
            require(not value["ignoredJobControl"], "native child inherited ignored job-control disposition")
            abandoned_receipt = root / "abandoned.json"
            abandoned = subprocess.Popen([str(args.binary.resolve()), "__launch-worker", sys.executable,
                str(Path(__file__).parent / "fixtures/terminal/launch_macos_fixture.py"), str(abandoned_receipt), str(write_fd)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                require(select.select([abandoned.stdout], [], [], 5)[0], "abandoned native PID handshake timed out")
                abandoned_wire = os.read(abandoned.stdout.fileno(), 4)
                require(len(abandoned_wire) == 4, "abandoned native launch omitted PID")
                abandoned_pid = struct.unpack("=i", abandoned_wire)[0]
                abandoned.stdin.close(); abandoned.stdin = None
                discarded, refusal = abandoned.communicate(timeout=8)
                require(abandoned.returncode != 0 and not discarded and b"InvalidLaunchAcknowledgement" in refusal,
                        "abandoned native launch was acknowledged")
                try:
                    os.kill(abandoned_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("abandoned detached child was not killed/reaped")
            finally:
                if abandoned.poll() is None:
                    abandoned.kill(); abandoned.wait(timeout=5)
            missing = subprocess.run([str(args.binary.resolve()), "__launch-worker", str(root / "nonexistent")],
                                     stdin=subprocess.DEVNULL, capture_output=True, timeout=8)
            require(missing.returncode != 0 and not missing.stdout and b"ExecFailed" in missing.stderr, "missing exec was reported as launch success")
            print("PASS macOS detached spawn:literal profile/argv, new session/group, inherited FD excluded, null stdio, clear signal mask, exec failure")
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            signal.signal(signal.SIGTTOU, old_ttou)
            if child is not None and child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            receipt.with_suffix(".release").write_text("owned witness acknowledged\n")
            if spawned_pid is not None:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        os.kill(spawned_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.01)
                else:
                    try:
                        if os.getsid(spawned_pid) == spawned_pid:
                            os.kill(spawned_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            os.close(read_fd)
            os.close(write_fd)


if __name__ == "__main__":
    main()
