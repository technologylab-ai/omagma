#!/usr/bin/env python3
"""Cooperative reservation for heavy film steps; see docs/VERIFICATION.md.

Acquisition first inspects existing build, measurement and media processes,
then uses one atomic mkdir. Busy or incomplete metadata is never removed.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import secrets
import socket
import sys

LOCK = Path(os.environ.get("OMAGMA_HOST_LOCK", "/tmp/zig-http-measurement.lock"))


def owner():
    try:
        value = json.loads((LOCK / "owner.json").read_text())
        return value if isinstance(value, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def process_stat(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[0], int(fields[1]), int(fields[19])
    except (OSError, IndexError, ValueError):
        return None


def start_ticks(pid):
    stat = process_stat(pid)
    return stat[2] if stat and stat[0] not in ("Z", "X") else None


def identity(data):
    try:
        pid = int(data.get("ownerPid", data.get("pid")))
        ticks = int(data.get("ownerStartTicks", data.get("pidStartTicks")))
        return pid, ticks
    except (TypeError, ValueError):
        return None


def busy():
    data = owner()
    who = identity(data) if data else None
    detail = f"owner PID {who[0]}" if who else "incomplete metadata"
    print(f"host reservation busy ({detail}); coordinate with its owner", file=sys.stderr)


def existing_work():
    # Exclude our own command chain; a build.sh coordinator is our ancestor.
    ancestors, pid = set(), os.getpid()
    while pid > 0 and pid not in ancestors:
        ancestors.add(pid)
        stat = process_stat(pid)
        if not stat:
            break
        pid = stat[1]
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal() or int(entry.name) in ancestors:
            continue
        try:
            argv = [s.decode(errors="replace") for s in (entry / "cmdline").read_bytes().split(b"\0") if s]
        except OSError:
            continue
        if not argv or start_ticks(int(entry.name)) is None:
            continue
        command, args = Path(argv[0]).name, argv[1:]
        heavy = command in {"ffmpeg", "ffprobe", "magick", "convert", "montage", "ninja", "gcc", "g++", "clang", "clang++", "rustc"}
        heavy |= command == "zig" and any(a in {"build", "test", "run", "build-exe", "build-lib", "build-obj"} for a in args)
        heavy |= command in {"cargo", "go", "make", "cmake"} and any(a in {"build", "test", "bench", "--build", "all"} for a in args)
        heavy |= command == "make" and not any(a in {"--version", "-v", "--help"} for a in args)
        heavy |= command in {"chromium", "chrome", "chromium-browser"} and any(a.startswith("--headless") for a in args)
        heavy |= (command in {"node", "uv"} or command.startswith("python")) and any(
            "video/render.mjs" in a or "video/capture/" in a or "video/analyze/" in a
            or ("tests/" in a and a.endswith((".py", ".mjs", ".js")))
            or "benchmark" in a or "measurement" in a or "memory_soak" in a for a in args)
        heavy |= "omagma" in command and "--fixtures" in args
        heavy |= command.startswith(("bench", "probe-", "probe_", "measurement", "memory-soak", "memory_soak"))
        if heavy:
            found.append((int(entry.name), command))
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("verify", "acquire", "release"))
    parser.add_argument("token", nargs="?")
    parser.add_argument("--pid", type=int, default=os.getppid())
    parser.add_argument("--purpose", default="omagma promo film capture/render/encode")
    args = parser.parse_args()
    if args.action == "acquire":
        if os.path.lexists(LOCK):
            busy()
            return 2
        ticks = start_ticks(args.pid) if args.pid > 0 else None
        if ticks is None:
            print("reservation owner PID must identify a live process", file=sys.stderr)
            return 1
        work = existing_work()
        if work:
            print("host has existing build/measurement/media work; coordinate before acquiring: " +
                  ", ".join(f"PID {pid} ({command})" for pid, command in work), file=sys.stderr)
            return 2
        try:
            LOCK.mkdir(mode=0o700)
        except FileExistsError:
            busy()
            return 2
        token = secrets.token_hex(16)
        data = {"owner": "omagma video/build.sh", "purpose": args.purpose, "hostname": socket.gethostname(),
                "startedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                "pid": args.pid, "pidStartTicks": ticks, "token": token, "cwd": os.getcwd()}
        temporary = LOCK / ".owner.json.tmp"
        temporary.write_text(json.dumps(data, indent=1) + "\n")
        temporary.rename(LOCK / "owner.json")
        print(token)
        return 0
    data = owner()
    if not args.token or not data or data.get("token") != args.token:
        print("host reservation is not held with this token", file=sys.stderr)
        return 1
    who = identity(data)
    if not who or who[0] <= 0 or start_ticks(who[0]) != who[1]:
        print("reservation owner identity is no longer live; coordinate recovery without removing the lock", file=sys.stderr)
        return 1
    if args.action == "release":
        (LOCK / "owner.json").unlink()
        LOCK.rmdir()
    return 0


if __name__ == "__main__":
    sys.exit(main())
