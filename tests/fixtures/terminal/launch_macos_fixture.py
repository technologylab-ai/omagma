#!/usr/bin/env python3
"""Owned detached-spawn witness; never launches a browser or desktop viewer."""
import json
import os
from pathlib import Path
import signal
import sys

receipt = Path(sys.argv[1])
inherited_fd = int(sys.argv[2])
try:
    os.fstat(inherited_fd)
    inherited = True
except OSError:
    inherited = False
receipt.write_text(json.dumps({
    "pid": os.getpid(), "session": os.getsid(0), "group": os.getpgrp(),
    "inheritedSentinel": inherited, "stdinEof": os.read(0, 1) == b"",
    "stdoutIsTty": os.isatty(1), "stderrIsTty": os.isatty(2),
    "argv": sys.argv[3:], "blockedSignals": sorted(int(value) for value in signal.pthread_sigmask(signal.SIG_BLOCK, [])),
}) + "\n")
