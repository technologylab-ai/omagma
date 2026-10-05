#!/usr/bin/env python3
"""Controlled editor checking the cooked tty supplied by Omagma suspension."""
import json
import os
from pathlib import Path
import sys
import termios
import tty


def main():
    path = Path(sys.argv[-1])
    log = Path(os.environ["OMAGMA_EDITOR_TEST_LOG"])
    settings = termios.tcgetattr(0)
    receipt = {"entered": True, "pid": os.getpid(), "processGroup": os.getpgrp(), "sessionId": os.getsid(0),
               "initialCanonical": bool(settings[3] & termios.ICANON), "initialEcho": bool(settings[3] & termios.ECHO),
               "stdinIsTty": sys.stdin.isatty(), "fileExists": path.is_file()}
    log.write_text(json.dumps(receipt))
    try:
        tty.setraw(0)
        os.write(1, b"\r\nOWNED MOUSE EDITOR: s save, x cancel\r\n")
        action = os.read(0, 1)
        if action == b"s": path.write_text("Fictional mouse editor body.\nCafé 👋 complete.\n")
        receipt.update(action=action.decode("ascii", errors="replace"), exited=True)
        log.write_text(json.dumps(receipt))
        return 0 if action == b"s" else 1
    finally:
        termios.tcsetattr(0, termios.TCSANOW, settings)


if __name__ == "__main__": sys.exit(main())
