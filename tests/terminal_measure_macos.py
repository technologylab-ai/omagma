#!/usr/bin/env python3
"""Native Darwin Safe CLI/TUI soaks; RSS/footprint are distinct from Linux PSS."""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import platform
import statistics
import sys
import tempfile
import threading
import time
from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, cache_limits, require
from terminal_macos import DarwinTerminal
from terminal_measure import allocator_receipt, cli_cycle, cli_quiet_pump, tui_cycle


class Rusage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'userTime', 'systemTime', 'packageIdleWakeups', 'interruptWakeups', 'pageins',
        'wiredBytes', 'residentBytes', 'footprintBytes', 'startTime', 'exitTime')]


library = None


def sample(pid):
    global library
    if library is None:
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        library.proc_pid_rusage.restype = ctypes.c_int
    value = Rusage()
    require(library.proc_pid_rusage(pid, 0, ctypes.byref(value)) == 0,
            'native owned-process resource sample failed')
    return {'monotonic': time.monotonic(), 'rssKiB': value.residentBytes / 1024,
            'footprintKiB': value.footprintBytes / 1024,
            'cpuNanoseconds': value.userTime + value.systemTime}


class Sampler:
    def __init__(self, pid):
        self.pid, self.count, self.error = pid, 0, None
        self.peak = {'rssKiB': 0, 'footprintKiB': 0}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run)

    def run(self):
        try:
            while not self.stop.is_set():
                value = sample(self.pid); self.count += 1
                for key in self.peak:
                    self.peak[key] = max(self.peak[key], value[key])
                self.stop.wait(.05)
        except Exception as error:
            self.error = type(error).__name__ + ': ' + str(error)

    def __enter__(self):
        self.thread.start(); return self

    def __exit__(self, *_):
        self.stop.set(); self.thread.join(3)
        require(not self.thread.is_alive() and self.error is None, 'native resource sampler cleanup/failure')


def quiet(process, duration, pump):
    pump(.25)
    before = sample(process.pid)
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        require(process.poll() is None, 'owned process exited in quiet interval')
        pump(min(.25, max(0, deadline - time.monotonic())))
    after = sample(process.pid)
    elapsed = after['monotonic'] - before['monotonic']
    cpu = (after['cpuNanoseconds'] - before['cpuNanoseconds']) / 1e9
    return {'elapsedSeconds': elapsed, 'cpuSeconds': cpu,
            'percentOfOneCore': cpu / elapsed * 100, 'before': before, 'after': after}


def measure(args, root, report):
    meter = root / 'allocator.json'
    extra = ('--metrics-file', str(meter))
    rows = []
    if args.kind == 'cli':
        with Client(args.binary, root / 'cli', extra=extra) as client:
            with Sampler(client.process.pid) as sampler:
                for index in range(args.warmup):
                    cli_cycle(client, index)
                for index in range(args.cycles):
                    cli_cycle(client, index + args.warmup)
                    rows.append(sample(client.process.pid))
                    if (index + 1) % 100 == 0:
                        print(f'CLI {index + 1}/{args.cycles}', flush=True)
                stats = [cache_limits(client, account) for account in ACCOUNTS]
                report['fixedReservationBytes'] = stats[0]['fixedBackendReservationBytes']
                before_frames = client.frame_count
                report['quiet'] = quiet(client.process, args.idle_seconds, lambda seconds: cli_quiet_pump(client, seconds))
                require(client.frame_count == before_frames, 'quiet CLI issued requests')
                report['quiet']['requestsIssued'] = 0
        require(client.process.returncode == 0 and not client.stderr, 'CLI did not cleanly exit')
    else:
        terminal = DarwinTerminal(args.binary, root / 'tui', extra=extra, history_limit=65536)
        try:
            terminal.until(lambda: 'Ready' in terminal.text() and 'Synthetic personal thread 031' in terminal.text())
            with Sampler(terminal.process.pid) as sampler:
                for index in range(args.warmup):
                    tui_cycle(terminal, index + 1)
                for index in range(args.cycles):
                    tui_cycle(terminal, index + args.warmup + 1)
                    rows.append(sample(terminal.process.pid))
                    if (index + 1) % 100 == 0:
                        print(f'TUI {index + 1}/{args.cycles}', flush=True)
                before_output = terminal.output_total
                report['quiet'] = quiet(terminal.process, args.idle_seconds, terminal.pump)
                report['quiet']['outputBytesAdded'] = terminal.output_total - before_output
                require(report['quiet']['outputBytesAdded'] == 0, 'quiet TUI rendered unsolicited frames')
            report['lifecycle'] = terminal.finish()
            with Client(args.binary, terminal.directory) as client:
                report['fixedReservationBytes'] = cache_limits(client, ACCOUNTS[0])['fixedBackendReservationBytes']
        finally:
            terminal.close()
    report['allocator'] = allocator_receipt(meter)
    require(report['allocator']['rejectedAllocations'] == 0, 'native soak rejected application allocations')
    require(report['fixedReservationBytes'] <= 16 * 1024**2, 'fixed backend reservation exceeds16MiB')
    quarter = max(1, len(rows) // 4)
    report['process'] = {'sampleCount': sampler.count, 'observedPeak': sampler.peak, 'metrics': {}}
    for key in ('rssKiB', 'footprintKiB'):
        first = statistics.median(row[key] for row in rows[:quarter])
        last = statistics.median(row[key] for row in rows[-quarter:])
        report['process']['metrics'][key] = {'earlyQuarterMedian': first, 'lateQuarterMedian': last,
                                           'warmMedianGrowth': last - first}
        require(last - first <= 4096, 'native warm process growth exceeded4MiB')
    require(report['quiet']['percentOfOneCore'] < .5, 'native quiet CPU exceeded0.5%of one core')
    report['completedCycles'] = len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--kind', required=True, choices=('cli', 'tui'))
    parser.add_argument('--cycles', type=int, default=1000)
    parser.add_argument('--warmup', type=int, default=100)
    parser.add_argument('--idle-seconds', type=float, default=60)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(sys.platform == 'darwin', 'native process qualification requires macOS')
    require(1 <= args.cycles <= 10000 and 0 <= args.warmup <= 1000 and 0 < args.idle_seconds <= 3600, 'invalid bounded soak')
    args.binary = args.binary.resolve()
    identity = read_build_info(args.binary, 'safe')
    report = {'platform': platform.platform(), 'architecture': platform.machine(), **identity,
              'binarySha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              'synthetic': True, 'liveWrites': False, 'desktopUsed': False,
              'kind': args.kind, 'cycles': args.cycles, 'warmup': args.warmup,
              'metricSource': 'Darwin proc_pid_rusage(RUSAGE_INFO_V0); RSS and physical footprint; no PSS or OS HWM'}
    try:
        with tempfile.TemporaryDirectory(prefix='omagma-macos-measure-') as temporary:
            measure(args, Path(temporary), report)
        report['passed'] = True
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        args.output.chmod(0o600)
    print(f'PASS macOS {args.kind}: {args.cycles}cycles, {args.idle_seconds}s quiet, bounded heap, RSS/footprint plateau, cleanup')


if __name__ == '__main__':
    main()
