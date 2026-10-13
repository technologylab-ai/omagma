#!/usr/bin/env python3
"""Development-only external editor fixture, used inside an isolated test PTY."""
import json
import os
from pathlib import Path
import sys
import tempfile
import termios
import tty

BODY = "Reviewed fixture editor body.\nCafé and emoji 👋 remain intact.\n"


def publish_receipt(log, receipt):
    fd, name = tempfile.mkstemp(prefix=f".{log.name}.", suffix=".tmp", dir=log.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(receipt))
        # Readers see either the complete entry receipt or the complete exit
        # receipt, never an existing path during truncation or a partial write.
        os.replace(temporary, log)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    path = Path(sys.argv[-1])
    log = Path(os.environ["OMAGMA_EDITOR_TEST_LOG"])
    publish_receipt(log, {"entered": True, "argv": sys.argv[1:-1], "fileExists": path.is_file(),
                          "stdinIsTty": sys.stdin.isatty(), "stdoutIsTty": sys.stdout.isatty(),
                          "pid": os.getpid(), "processGroup": os.getpgrp(), "sessionId": os.getsid(0)})
    settings = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        os.write(1, b"\r\nOMAGMA TEST EDITOR: s saves, x cancels, r saves then fails, f replaces with FIFO\r\n")
        action = os.read(0, 1)
        if action in {b"s", b"r"}:
            path.write_text(BODY)
        elif action == b"f":
            path.unlink()
            os.mkfifo(path, 0o600)
        result = 0 if action in {b"s", b"f"} else 1
        receipt = json.loads(log.read_text())
        receipt.update(action=action.decode("ascii", errors="replace"), exitCode=result)
        publish_receipt(log, receipt)
        return result
    finally:
        termios.tcsetattr(0, termios.TCSANOW, settings)


if __name__ == "__main__":
    raise SystemExit(main())
