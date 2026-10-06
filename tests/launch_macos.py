#!/usr/bin/env python3
"""Native spawn flag/exec handshake regression with a fictional detached child."""
import argparse
import json
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
        try:
            child = subprocess.Popen([str(args.binary.resolve()), "__launch-worker", sys.executable,
                str(Path(__file__).parent / "fixtures/terminal/launch_macos_fixture.py"), str(receipt), str(write_fd),
                "--profile-directory=Profile Fictional", f"literal $(touch {sentinel})"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=False)
            out, error = child.communicate(timeout=8)
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
            missing = subprocess.run([str(args.binary.resolve()), "__launch-worker", str(root / "nonexistent")],
                                     stdin=subprocess.DEVNULL, capture_output=True, timeout=8)
            require(missing.returncode != 0 and not missing.stdout and b"ExecFailed" in missing.stderr, "missing exec was reported as launch success")
            print("PASS macOS detached spawn:literal profile/argv, new session/group, inherited FD excluded, null stdio, clear signal mask, exec failure")
        finally:
            os.close(read_fd)
            os.close(write_fd)


if __name__ == "__main__":
    main()
