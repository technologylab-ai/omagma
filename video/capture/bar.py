#!/usr/bin/env python3
"""Capture the real Omarchy bar dropdown states for the film, entirely offscreen.

    python3 video/capture/bar.py --binary zig-out/bin/omagma --out video/cache/capture/bar

Runs the repository's offscreen Quickshell test shell (QT_QPA_PLATFORM=offscreen,
no native surface, no compositor input) with the fixture backend, injects
fictional snapshots exactly as tests/ui_capture.py --publication does, and
grabs a PNG per state. Never reads a user configuration or mailbox and never
touches the installed desktop plugin.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))

from promo_fixture import ACCOUNTS, OPTIONAL_MAIL, PERSONAL_MAIL, ROOT, WORK, WORK_MAIL  # noqa: E402
from terminal_publication import complete_png, strip_png_metadata  # noqa: E402

UNREAD = {"personal@example.com": 3, "work@example.com": 6, "optional@example.com": 2}
STATES = (  # (file stem, action, argument)
    ("00-personal", "select", ACCOUNTS[0]),
    ("01-work", "select", WORK),
    ("02-work-first", "selectMessage", "bar-work-0"),
    ("03-work-second", "moveSelection", "1"),
    ("04-work-third", "moveSelection", "1"),
    ("05-optional", "select", ACCOUNTS[2]),
)


def snapshot(account, now_ms):
    key = account.split("@")[0]
    entries = {"personal": PERSONAL_MAIL, "work": WORK_MAIL, "optional": OPTIONAL_MAIL}[key]
    messages = [{"id": f"bar-{key}-{index}", "threadId": f"bar-{key}-thread-{index}", "sender": sender,
                 "subject": subject, "snippet": snippet, "receivedAt": now_ms - index * 2700000, "unread": unread}
                for index, (sender, _address, subject, snippet, unread) in enumerate(entries[:9])]
    return {"ev": "snapshot", "account": account, "enabled": True, "required": account != ACCOUNTS[2],
            "generation": 10000, "state": "current", "checkedAt": now_ms // 1000, "unread": UNREAD[account],
            "partial": False, "error": "", "retryAt": 0, "messages": messages}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--out", type=Path, default=ROOT / "video/cache/capture/bar")
    parser.add_argument("--scale", type=int, default=2, choices=(2, 3))
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="omagma-promo-bar-") as temporary:
        directory = Path(temporary)
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_SCALE_FACTOR=str(args.scale),
                   OMAGMA_TEST_BINARY=str(args.binary.resolve()), OMAGMA_TEST_FONT_BASE="12",
                   OMAGMA_TEST_FONT="JetBrainsMono Nerd Font",
                   OMAGMA_TEST_CONFIG=str(ROOT / "tests/fixtures/all-accounts.json"), HOME=str(directory / "home"), TZ="UTC")
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(name, None)
        for name in ("CONFIG", "CACHE", "DATA", "STATE"):
            env[f"XDG_{name}_HOME"] = str(directory / name.lower())
        runtime = directory / "runtime"
        runtime.mkdir(mode=0o700)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        log_path = out / "quickshell.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(["quickshell", "--path", str(ROOT / "offscreen.qml"), "--no-color"],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)

            def call(method, *fields):
                return subprocess.check_output(["quickshell", "ipc", "--pid", str(process.pid), "call", "omagma-test",
                                                method, *fields], env=env, text=True, stderr=subprocess.PIPE, timeout=5).strip()

            def until(predicate, seconds=10):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    assert process.poll() is None, f"Quickshell stopped; see {log_path.name}"
                    try:
                        state = json.loads(call("state"))
                        if predicate(state):
                            return state
                    except (subprocess.CalledProcessError, json.JSONDecodeError):
                        pass
                    time.sleep(.05)
                raise AssertionError(f"bar state timed out; see {log_path.name}")

            def capture(stem):
                image = out / f"{stem}.png"
                image.unlink(missing_ok=True)
                time.sleep(.35)
                call("capture", str(image))
                deadline = time.monotonic() + 5
                while not complete_png(image) and time.monotonic() < deadline:
                    time.sleep(.05)
                assert complete_png(image), f"bar state {stem} was not completely saved"
                strip_png_metadata(image)
                return image.name

            try:
                until(lambda state: state["daemon"] == "ready")
                call("open")
                until(lambda state: state["pending"] == 0)
                now_ms = int(time.time() * 1000)
                for account in ACCOUNTS:
                    call("inject", json.dumps(snapshot(account, now_ms), ensure_ascii=False, separators=(",", ":")))
                until(lambda state: len(state["accounts"]) == 3 and all(
                    account["state"] == "current" and account["generation"] == 10000 for account in state["accounts"]))
                frames = []
                for stem, action, argument in STATES:
                    call(action, argument)
                    if action == "select":
                        until(lambda state: state["selected"] == argument and state["pending"] == 0)
                    frames.append({"file": capture(stem), "action": action, "argument": argument})
                call("close")
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    log_text = log_path.read_text()
    for warning in ("TypeError", "ReferenceError", "Failed to load configuration", "Binding loop", "Error decoding", "Cannot open"):
        assert warning not in log_text, f"bar capture warning {warning!r}; see {log_path.name}"
    (out / "bar.json").write_text(json.dumps({"scale": args.scale, "frames": frames, "source": "offscreen.qml test shell, fictional injected snapshots"}, indent=1) + "\n")
    print(f"bar: {len(frames)} states -> {out}")


if __name__ == "__main__":
    main()
