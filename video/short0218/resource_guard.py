#!/usr/bin/env python3
"""Own and bound one promo workload; never signal another owner's processes."""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import json
import math
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import time

LOCK = Path(os.environ.get("OMAGMA_HOST_LOCK", "/tmp/zig-http-measurement.lock"))
ROOT = Path(__file__).resolve().parents[2]
PS = "/bin/ps"


def cpu_seconds(value):
    days, _, clock = value.partition("-")
    days, clock = (int(days), clock) if clock else (0, days)
    parts = [float(part) for part in clock.split(":")]
    if not 1 <= len(parts) <= 3 or any(part < 0 or not math.isfinite(part) for part in parts):
        raise ValueError("invalid process CPU time")
    return days * 86400 + sum(part * 60 ** index for index, part in enumerate(reversed(parts)))


def processes():
    raw = subprocess.check_output([PS, "-axo", "pid=,ppid=,pgid=,rss=,time=,stat=,lstart="], text=True)
    rows = {}
    for line in raw.splitlines():
        fields = line.split(None, 6)
        if len(fields) != 7:
            continue
        pid, ppid, pgid, rss, cpu, state, born = fields
        value = dict(pid=int(pid), ppid=int(ppid), pgid=int(pgid), rss=int(rss) * 1024,
                     cpu=cpu_seconds(cpu), state=state, born=born)
        if sys.platform.startswith("linux"):
            try:
                stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                value["born"] = stat[19]
                value["cpu"] = (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK")
            except (OSError, IndexError, ValueError):
                continue
        rows[value["pid"]] = value
    return rows


def identity(pid, table=None):
    row = (table if table is not None else processes()).get(pid)
    return row["born"] if row and not row["state"].startswith(("Z", "X")) else None


def read_owner():
    value = json.loads((LOCK / "owner.json").read_text())
    if not isinstance(value, dict):
        raise ValueError("incomplete host reservation")
    return value


def verify(token):
    owner = read_owner()
    if not token or owner.get("token") != token or owner.get("hostname") != socket.gethostname():
        raise ValueError("matching host-local ownership token required")
    pid = int(owner.get("ownerPid", owner.get("pid", 0)))
    expected = owner.get("ownerStartTicks", owner.get("pidStartTicks", owner.get("startTicks", owner.get("processIdentity"))))
    if pid <= 0 or expected is None or str(identity(pid)) != str(expected):
        raise ValueError("host reservation owner is not the same live process")
    return owner


def acquire(pid, purpose):
    born = identity(pid)
    if born is None:
        raise ValueError("reservation owner must be a live process")
    # Existing host work must be inspected/coordinated by the caller first.
    # Atomic mkdir is the only acquisition operation; uncertain locks stay put.
    LOCK.mkdir(mode=0o700)
    token = secrets.token_hex(16)
    owner = dict(owner="omagma short0218", purpose=purpose, hostname=socket.gethostname(),
                 startedUtc=dt.datetime.now(dt.timezone.utc).isoformat(), pid=pid,
                 processIdentity=born, token=token, cwd=os.getcwd())
    if sys.platform.startswith("linux"):
        owner["pidStartTicks"] = int(born)
    temporary = LOCK / ".owner.json.tmp"
    temporary.write_text(json.dumps(owner, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.rename(LOCK / "owner.json")
    return token


def release(token):
    verify(token)
    (LOCK / "owner.json").unlink()
    LOCK.rmdir()


def owned_processes(table, root_pid, known):
    """Retain identity-bound descendants even if an owned parent exits."""
    selected = {pid for pid, born in known.items() if pid in table and table[pid]["born"] == born}
    if root_pid in table and (root_pid not in known or known[root_pid] == table[root_pid]["born"]):
        selected.add(root_pid)
    changed = True
    while changed:
        changed = False
        for pid, row in table.items():
            if pid not in selected and row["ppid"] in selected:
                selected.add(pid)
                changed = True
    # All members of the freshly isolated root session's process group belong
    # to this job, including a child reparented between adjacent samples.
    for pid, row in table.items():
        if row["pgid"] == root_pid and (pid not in known or known[pid] == row["born"]):
            selected.add(pid)
        elif row["ppid"] == os.getpid() and row["pgid"] != os.getpgrp():
            # Linux subreaper adoption also covers a PTY child's own session.
            selected.add(pid)
    for pid in selected:
        known[pid] = table[pid]["born"]
    return {pid: table[pid] for pid in selected if not table[pid]["state"].startswith(("Z", "X"))}


def signal_owned(rows, signum, known):
    # Recheck identity and group immediately before each signal. PID reuse
    # cannot turn a sampled descendant into an unrelated signal target.
    fresh = processes()
    for pid, old in rows.items():
        now = fresh.get(pid)
        if now and now["born"] == known.get(pid) == old["born"] and now["pgid"] == old["pgid"]:
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass


def cleanup(child, known):
    rows = owned_processes(processes(), child.pid, known)
    signal_owned(rows, signal.SIGCONT, known)
    signal_owned(rows, signal.SIGTERM, known)
    deadline = time.monotonic() + 3
    while rows and time.monotonic() < deadline:
        child.poll()
        time.sleep(.05)
        rows = owned_processes(processes(), child.pid, known)
    if rows:
        signal_owned(rows, signal.SIGKILL, known)
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        # The direct child is an identity-owned process, never a name match.
        rows = owned_processes(processes(), child.pid, known)
        signal_owned(rows, signal.SIGKILL, known)
        child.wait(timeout=3)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        rows = owned_processes(processes(), child.pid, known)
        if not rows:
            return []
        time.sleep(.05)
    return sorted(rows)


def safe_report(path):
    # Normalize lexical '..' before the allowlist check, but reject symlink
    # ancestors independently instead of resolving them into an allowed path.
    path = Path(os.path.abspath(path))
    allowed = (ROOT / "video/cache/short0218", ROOT / "video/out/short0218")
    if not any(path.is_relative_to(base) for base in allowed):
        raise ValueError("report must be inside video/cache/short0218 or video/out/short0218")
    current = path.parent
    while current != ROOT.parent:
        if current.is_symlink():
            raise ValueError("report parent must not be a symlink")
        current = current.parent
    if path.exists() or path.is_symlink():
        raise ValueError("refusing to overwrite a previous resource receipt")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def run(args):
    if not args.command:
        raise ValueError("a command after -- is required")
    command = args.command[1:] if args.command[0] == "--" else args.command
    if not command or not .05 <= args.sample <= .25 or not 0 < args.cpu_cores <= 2 or not .25 <= args.rss_gib <= 4 or not 15 <= args.nice <= 19 or args.wall_seconds < 0:
        raise ValueError("budget must be <=2 CPU cores, .25–4 GiB RSS, nice15–19, sample .05–.25s")
    report = safe_report(args.report)
    own_lock = args.acquire
    token = acquire(os.getpid(), args.purpose) if own_lock else os.environ.get("HOST_TOKEN", "")
    verify(token)
    affinity = None
    if sys.platform.startswith("linux"):
        # Orphaned owned descendants become reapable children on Linux.
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "could not become child subreaper")
        # The kernel bounds instantaneous parallelism even after a long idle
        # interval; cumulative CPU accounting below also enforces fractions.
        affinity = sorted(os.sched_getaffinity(0))[:math.ceil(args.cpu_cores)]
        if not affinity:
            raise ValueError("no inherited Linux CPU affinity is available")
    child = None
    known, maxima = {}, {}
    started = time.monotonic()
    started_utc = dt.datetime.now(dt.timezone.utc).isoformat()
    peak_rss = 0
    max_cpu_rate = 0.0
    throttle_seconds = 0.0
    throttle_count = 0
    stopped = False
    stopped_at = None
    failure = None
    interrupted = None
    previous_handlers = {}

    def interrupt(signum, _frame):
        nonlocal interrupted
        interrupted = signum

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous_handlers[signum] = signal.signal(signum, interrupt)
    try:
        def low_priority():
            os.setpriority(os.PRIO_PROCESS, 0, max(args.nice, os.getpriority(os.PRIO_PROCESS, 0)))
            if affinity is not None:
                os.sched_setaffinity(0, affinity)
        env = dict(os.environ, HOST_TOKEN=token, OMAGMA_RESOURCE_GUARD="short0218",
                   OMAGMA_RESOURCE_GUARD_PID=str(os.getpid()))
        child = subprocess.Popen(command, env=env, start_new_session=True, preexec_fn=low_priority)
        last_wall, last_cpu = started, 0.0
        while True:
            now = time.monotonic()
            table = processes()
            rows = owned_processes(table, child.pid, known)
            if len(known) > 1024:
                failure = "owned-process limit exceeded"
                break
            for pid, row in rows.items():
                key = f"{pid}:{row['born']}"
                maxima[key] = max(maxima.get(key, 0), row["cpu"])
            cpu = sum(maxima.values())
            rss = sum(row["rss"] for row in rows.values())
            peak_rss = max(peak_rss, rss)
            if now > last_wall:
                max_cpu_rate = max(max_cpu_rate, (cpu - last_cpu) / (now - last_wall))
            last_wall, last_cpu = now, cpu
            if rss > args.rss_gib * 1024**3:
                failure = "aggregate RSS cap exceeded"
                break
            if interrupted:
                failure = f"interrupted by signal {interrupted}"
                break
            if args.wall_seconds and now - started > args.wall_seconds:
                failure = "wall deadline exceeded"
                break
            verify(token)
            if child.poll() is not None:
                break
            # CPU is aggregate elapsed process time, not one process's %CPU.
            # Short bounded stop periods repay excess CPU time at <=2 cores.
            debt = cpu - args.cpu_cores * (now - started)
            if debt > .10:
                if not stopped:
                    signal_owned(rows, signal.SIGSTOP, known)
                    stopped = True
                    stopped_at = time.monotonic()
                    throttle_count += 1
                delay = min(.50, max(.02, debt / args.cpu_cores))
                time.sleep(delay)
                signal_owned(owned_processes(processes(), child.pid, known), signal.SIGCONT, known)
                throttle_seconds += time.monotonic() - stopped_at
                stopped = False
                stopped_at = None
                time.sleep(.01)  # A stop never withholds progress indefinitely.
            else:
                time.sleep(args.sample)
        status = child.poll()
    except BaseException as error:
        failure = f"{type(error).__name__}: {error}"
        status = None
    finally:
        survivors = []
        if child is not None:
            if stopped and stopped_at is not None:
                throttle_seconds += time.monotonic() - stopped_at
            survivors = cleanup(child, known)
            status = child.returncode
            if sys.platform.startswith("linux"):
                while True:
                    try:
                        pid, _ = os.waitpid(-1, os.WNOHANG)
                        if pid == 0:
                            break
                    except ChildProcessError:
                        break
        if survivors:
            failure = failure or "owned descendants survived cleanup"
        elapsed = time.monotonic() - started
        record = dict(schema="omagma.video.resources.v1", passed=failure is None and status == 0,
                      command=command, platform=sys.platform, exitCode=status, error=failure,
                      cpuBudgetCores=args.cpu_cores, rssLimitBytes=int(args.rss_gib * 1024**3),
                      requestedNice=args.nice, sampleSeconds=args.sample, cpuAffinity=affinity,
                      guardPid=os.getpid(), rootPid=child.pid if child is not None else None,
                      peakAggregateRssBytes=peak_rss, observedCpuSeconds=sum(maxima.values()),
                      observedAverageCpuCores=sum(maxima.values()) / elapsed if elapsed else 0,
                      peakSampleCpuCores=max_cpu_rate, throttleSeconds=throttle_seconds,
                      throttleCount=throttle_count, wallSeconds=elapsed,
                      ownedPids=sorted(known), survivingOwnedPids=survivors,
                      startedUtc=started_utc, completedUtc=dt.datetime.now(dt.timezone.utc).isoformat(),
                      accounting="sampled aggregate RSS and cumulative owned-process CPU; Linux inherited CPU affinity bounds parallelism; stop duty repays fractional CPU debt; RSS is not kernel isolation")
        report.write_text(json.dumps(record, indent=2) + "\n")
        report.chmod(0o600)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if own_lock:
            release(token)
    return 0 if record["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("acquire", "verify", "release"):
        item = sub.add_parser(action)
        if action == "acquire":
            item.add_argument("--pid", type=int, default=os.getppid())
            item.add_argument("--purpose", default="omagma short0218 media workload")
        else:
            item.add_argument("token", nargs="?", default=os.environ.get("HOST_TOKEN", ""))
    item = sub.add_parser("run")
    item.add_argument("--report", type=Path, required=True)
    item.add_argument("--cpu-cores", type=float, default=2)
    item.add_argument("--rss-gib", type=float, default=4)
    item.add_argument("--nice", type=int, default=15)
    item.add_argument("--sample", type=float, default=.1)
    item.add_argument("--wall-seconds", type=float, default=0)
    item.add_argument("--acquire", action="store_true", help="reserve this already-inspected host for this run only")
    item.add_argument("--purpose", default="omagma short0218 capture/render/encode")
    item.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "verify":
        verify(args.token)
        return 0
    if args.action == "release":
        release(args.token)
        return 0
    if args.action == "acquire":
        print(acquire(args.pid, args.purpose))
        return 0
    return run(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"resource guard: {error}", file=sys.stderr)
        raise SystemExit(1)
