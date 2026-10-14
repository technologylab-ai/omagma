#!/usr/bin/env python3
"""Let Zig's per-test timeout terminate an owned POSIX test process reliably.

The Maker owns the timer and test protocol. Its SIGTERM reaches this supervisor,
which bounds graceful cleanup even when a test installs its own TERM handler.
There is deliberately no compilation or whole-test-binary deadline here.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

CLEANUP_GRACE = 0.5


def terminate_owned(child):
    # Do not poll/wait during grace: the unreaped session leader pins its PGID
    # even if TERM makes it exit while a descendant still ignores that signal.
    assert child.returncode is None
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            # Darwin can report EPERM when only the zombie leader remains.
            # Prove exit by reaping; a live-child refusal is still an error.
            try:
                child.wait(timeout=0)
            except subprocess.TimeoutExpired:
                raise error from None
            return  # The PGID is no longer pinned: never signal it again.
        if sig == signal.SIGTERM:
            time.sleep(CLEANUP_GRACE)
    child.wait()


def supervise(argv):
    requested_signal = 0

    def stop(signum, _frame):
        nonlocal requested_signal
        requested_signal = requested_signal or signum

    previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT)}
    child = None
    try:
        progress = os.environ.get("ZIG_PROGRESS")
        pass_fds = ()
        if progress is not None:
            fd = int(progress)
            if fd < 3:
                raise ValueError("ZIG_PROGRESS must name an inherited progress descriptor")
            os.fstat(fd)  # Refuse a stale descriptor instead of dropping progress.
            pass_fds = (fd,)
        # stdio and all argv (including seed/cache/listen) are inherited exactly.
        # A signal during Popen only sets the flag; ownership begins on return.
        child = subprocess.Popen(argv, start_new_session=True, pass_fds=pass_fds)
        while not requested_signal:
            try:
                return child.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                pass
        return -requested_signal
    finally:
        try:
            if child is not None and child.returncode is None:
                terminate_owned(child)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


def exit_with_status(status):
    if status < 0:
        sig = -status
        if sig not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(sig, signal.SIG_DFL)
        os.kill(os.getpid(), sig)
        raise SystemExit(128 + sig)
    raise SystemExit(status)


if __name__ == "__main__":
    if os.name != "posix" or len(sys.argv) < 3 or sys.argv[1] != "--":
        raise SystemExit("usage: zig_test_guard.py -- TEST_EXECUTABLE [ARG ...] (POSIX only)")
    exit_with_status(supervise(sys.argv[2:]))
