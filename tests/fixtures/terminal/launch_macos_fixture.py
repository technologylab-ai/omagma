#!/usr/bin/env python3
"""Owned detached-spawn witness; never launches a browser or desktop viewer."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time

receipt = Path(sys.argv[1])
inherited_fd = int(sys.argv[2])
try:
    os.fstat(inherited_fd)
    inherited = True
except OSError:
    inherited = False
payload = json.dumps({
    "pid": os.getpid(), "session": os.getsid(0), "group": os.getpgrp(),
    "inheritedSentinel": inherited, "stdinEof": os.read(0, 1) == b"",
    "stdoutIsTty": os.isatty(1), "stderrIsTty": os.isatty(2),
    "ignoredJobControl": signal.getsignal(signal.SIGTTOU) == signal.SIG_IGN,
    "argv": sys.argv[3:], "blockedSignals": sorted(int(value) for value in signal.pthread_sigmask(signal.SIG_BLOCK, [])),
}) + "\n"
fd, name = tempfile.mkstemp(prefix=f".{receipt.name}.", suffix=".tmp", dir=receipt.parent)
temporary = Path(name)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(payload)
    # Existence is the parent's readiness signal; publish only complete JSON.
    os.replace(temporary, receipt)
finally:
    temporary.unlink(missing_ok=True)

# Pin this exact owned PID until the parent acknowledges its receipt.
deadline = time.monotonic() + 10
while not receipt.with_suffix(".release").exists() and time.monotonic() < deadline:
    time.sleep(.01)
