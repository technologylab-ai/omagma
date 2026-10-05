#!/usr/bin/env python3
"""Safe fixture terminal lifecycle/quiet evidence; use the cooperative host lock."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import statistics
import tempfile
import threading
import time

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, FIXTURES, cache_limits, list_all, require
from terminal_pty import Terminal
from terminal_reader import reader_contains

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 64 * 1024**2


def process_sample(pid):
    result = {"monotonic": time.monotonic()}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        key, _, value = line.partition(":")
        if key in {"VmRSS", "VmHWM", "Threads"}:
            result[key] = int(value.split()[0])
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    result["cpuTicks"] = int(fields[11]) + int(fields[12])
    rollup = {}
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        key, _, value = line.partition(":")
        if key in {"Rss", "Pss", "Private_Clean", "Private_Dirty", "Pss_Anon", "Pss_File"}:
            rollup[key] = int(value.split()[0])
    result.update(rssKiB=rollup["Rss"], pssKiB=rollup["Pss"],
                  privateKiB=rollup.get("Private_Clean", 0) + rollup.get("Private_Dirty", 0),
                  pssAnonKiB=rollup.get("Pss_Anon", 0), pssFileKiB=rollup.get("Pss_File", 0))
    return result


class Sampler:
    """Keep aggregates rather than growing a second unbounded sample history."""
    def __init__(self, pid):
        self.pid, self.count, self.error = pid, 0, None
        self.peaks = {"rssKiB": 0, "pssKiB": 0, "VmHWM": 0, "Threads": 0}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            try:
                sample = process_sample(self.pid)
            except (FileNotFoundError, ProcessLookupError):
                return
            except Exception as error:
                self.error = f"{type(error).__name__}: {error}"
                return
            self.count += 1
            for key in self.peaks:
                self.peaks[key] = max(self.peaks[key], sample[key])
            self.stop.wait(.05)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=3)
        require(not self.thread.is_alive(), "sampler did not stop within finite deadline")
        require(self.error is None, f"process sampler failed: {self.error}")


def allocator_receipt(path):
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, "allocator receipt is not private")
    value = json.loads(path.read_text())
    require(set(value) == {"allocatorUsedBytes", "allocatorPeakBytes", "rejectedAllocations", "allocatorLimitBytes"},
            "allocator receipt includes unexpected or missing fields")
    require(all(type(number) is int and number >= 0 for number in value.values()), "invalid allocator receipt")
    require(value["allocatorUsedBytes"] <= value["allocatorPeakBytes"] <= value["allocatorLimitBytes"] == LIMIT,
            "terminal heap allocations exceeded64MiB")
    return value


def cli_cycle(client, index):
    account = ACCOUNTS[index % len(ACCOUNTS)]
    list_all(client, account, label="INBOX")
    cases = [1, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 48, 96]
    suffix = cases[(index // len(ACCOUNTS)) % len(cases)]
    message = client.request("mail.read", account, messageId=f"shared-msg-{suffix:03}")
    require(message["id"] == f"shared-msg-{suffix:03}" and type(message["bodyText"]) is str,
            "soak full read lost message identity/body")
    if index % 10 == 0:
        thread = client.request("mail.thread", account, threadId=message["threadId"])
        require(len(thread["messages"]) == 3, "soak thread mixed or omitted messages")


def tui_action(terminal, key, predicate):
    before = terminal.output_total
    terminal.send(key)
    terminal.until(lambda: terminal.output_total > before and "Ready" in terminal.text() and predicate())


def tui_cycle(terminal, index):
    key = ACCOUNTS[index % len(ACCOUNTS)].split("@")[0]
    tui_action(terminal, str(1 + index % len(ACCOUNTS)).encode(),
               lambda: f"Synthetic {key} thread 031" in terminal.text())
    tui_action(terminal, b"]", lambda: f"Synthetic {key} thread 021" in terminal.text())
    tui_action(terminal, b"[", lambda: f"Synthetic {key} thread 031" in terminal.text())
    tui_action(terminal, b"j", lambda: reader_contains(terminal.screen, f"Synthetic {key}@example.com message 095."))
    tui_action(terminal, b"\x12", lambda: reader_contains(terminal.screen, f"Synthetic {key}@example.com message 095."))


def quiet(process, seconds, pump):
    time.sleep(.25)  # Let the last completed response/paint finish its cleanup.
    before = process_sample(process.pid)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require(process.poll() is None, "owned process exited during quiet window")
        pump(min(.25, max(0, deadline - time.monotonic())))
    after = process_sample(process.pid)
    elapsed = after["monotonic"] - before["monotonic"]
    cpu = (after["cpuTicks"] - before["cpuTicks"]) / os.sysconf("SC_CLK_TCK")
    return {"elapsedSeconds": round(elapsed, 4), "cpuSeconds": cpu,
            "percentOfOneCore": round(cpu / elapsed * 100, 6), "before": before, "after": after}


def cli_quiet_pump(client, seconds):
    for key, _ in client.selector.select(seconds):
        data = os.read(key.fileobj.fileno(), 65536)
        require(not data, "CLI emitted unsolicited output in quiet window")
        require(client.process.poll() is None, "CLI closed output during quiet window")


def summarize(report, samples, baseline, sampler):
    quarter = max(1, len(samples) // 4)
    report["process"] = {"cold": baseline, "sampleCount": sampler.count,
                         "observedPeakRssKiB": sampler.peaks["rssKiB"],
                         "observedSamplePeakPssKiB": sampler.peaks["pssKiB"],
                         "osHighWaterRssKiB": sampler.peaks["VmHWM"], "maxThreads": sampler.peaks["Threads"]}
    for key in ["rssKiB", "pssKiB", "privateKiB"]:
        early = statistics.median(s[key] for s in samples[:quarter])
        late = statistics.median(s[key] for s in samples[-quarter:])
        report["process"][key] = {"earlyQuarterMedian": early, "lateQuarterMedian": late,
                                   "warmMedianGrowth": late - early}
    report["cycleSamples"] = samples
    report["checks"] = {"warmRssPlateau": report["process"]["rssKiB"]["warmMedianGrowth"] <= 4096,
                        "warmPssPlateau": report["process"]["pssKiB"]["warmMedianGrowth"] <= 4096,
                        "quietCpuUnderHalfPercent": report["quiet"]["percentOfOneCore"] < .5,
                        "terminalHeapPeakWithin64MiB": report["allocator"]["allocatorPeakBytes"] <= LIMIT,
                        "noRejectedAllocations": report["allocator"]["rejectedAllocations"] == 0}


def measure_workload(args, report, directory):
    metrics = directory / "allocator.json"
    extra = ("--metrics-file", str(metrics))
    rows = []
    report["cycleSamples"] = rows
    if args.kind == "cli":
        with Client(args.binary, directory / "cli", extra=extra) as client:
            baseline = process_sample(client.process.pid)
            report["processInitial"] = baseline
            with Sampler(client.process.pid) as sampler:
                report["processPartialPeak"] = sampler.peaks
                for index in range(args.warmup):
                    cli_cycle(client, index)
                report["warmMetrics"] = [cache_limits(client, account) for account in ACCOUNTS]
                started = time.monotonic()
                for index in range(args.cycles):
                    cli_cycle(client, args.warmup + index)
                    rows.append({"cycle": index + 1, **process_sample(client.process.pid)})
                    if (index + 1) % 100 == 0:
                        print(f"CLI {index+1}/{args.cycles}: RSS{rows[-1]['rssKiB']}KiB PSS{rows[-1]['pssKiB']}KiB", flush=True)
                report["soakSeconds"] = round(time.monotonic() - started, 4)
                report["finalMetrics"] = [cache_limits(client, account) for account in ACCOUNTS]
                before_frames = client.frame_count
                report["quiet"] = quiet(client.process, args.idle_seconds, lambda seconds: cli_quiet_pump(client, seconds))
                require(client.frame_count == before_frames, "quiet window issued CLI requests")
                report["quiet"]["requestsIssued"] = 0
                report["frames"] = client.frame_count
            require(all(m["metadataEntries"] >= 96 for m in report["finalMetrics"]), "soak failed to retain >30rows/account")
        require(client.process.returncode == 0 and not client.stderr, "CLI soak did not exit cleanly")
        report["workload"] = {"fullPaginationCycles": args.cycles, "pageRequests": args.cycles * 8,
                              "fullReads": args.cycles, "fixtureMessagesPerAccount": 96, "accounts": ACCOUNTS}
        report["fixedReservationBytes"] = report["finalMetrics"][0]["fixedBackendReservationBytes"]
    else:
        terminal = Terminal(args.binary, directory / "tui", extra=extra, history_limit=65536)
        try:
            terminal.until(lambda: "Ready" in terminal.text() and "Synthetic personal thread 031" in terminal.text())
            baseline = process_sample(terminal.process.pid)
            report["processInitial"] = baseline
            with Sampler(terminal.process.pid) as sampler:
                report["processPartialPeak"] = sampler.peaks
                for index in range(args.warmup):
                    tui_cycle(terminal, index + 1)
                started = time.monotonic()
                for index in range(args.cycles):
                    tui_cycle(terminal, args.warmup + index + 1)
                    rows.append({"cycle": index + 1, **process_sample(terminal.process.pid)})
                    if (index + 1) % 100 == 0:
                        print(f"TUI {index+1}/{args.cycles}: RSS{rows[-1]['rssKiB']}KiB PSS{rows[-1]['pssKiB']}KiB", flush=True)
                report["soakSeconds"] = round(time.monotonic() - started, 4)
                before_output = terminal.output_total
                report["quiet"] = quiet(terminal.process, args.idle_seconds, terminal.pump)
                report["quiet"]["inputKeysIssued"] = 0
                report["quiet"]["outputBytesAdded"] = terminal.output_total - before_output
                require(report["quiet"]["outputBytesAdded"] == 0, "quiet TUI kept rendering unsolicited frames")
            report["lifecycle"] = terminal.finish()
            with Client(args.binary, terminal.directory) as client:
                cache = []
                for account in ACCOUNTS:
                    stats = cache_limits(client, account)
                    require(stats["metadataEntries"] >= 64, "TUI soak did not retain two pages/account")
                    cache.append({"account": account, **{key: stats[key] for key in
                        ["metadataEntries", "metadataLimit", "diskBytes", "diskLimitBytes", "bodyLimitBytes"]}})
                report["cacheAfterTuiExit"] = cache
                report["fixedReservationBytes"] = stats["fixedBackendReservationBytes"]
            report["workload"] = {"navigationReloadCycles": args.cycles, "actionsPerCycle": 5,
                                  "fixtureMessagesPerAccount": 96, "accounts": ACCOUNTS,
                                  "retainedHarnessHistoryBytes": len(terminal.output)}
        except Exception:
            report["failureCurrentCells"] = terminal.text().splitlines()
            raise
        finally:
            terminal.close()
    report["allocator"] = allocator_receipt(metrics)
    summarize(report, rows, baseline, sampler)


def measure(args, report, directory):
    try:
        measure_workload(args, report, directory)
    finally:
        report["completedCycles"] = len(report.get("cycleSamples", []))
        metrics = directory / "allocator.json"
        if metrics.exists() and "allocator" not in report:
            # Preserve the actual exit meter even when another measurement gate fails.
            report["allocatorAtExit"] = json.loads(metrics.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--kind", choices=["cli", "tui"], required=True)
    parser.add_argument("--cycles", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=100)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    require(1 <= args.cycles <= 10000 and 0 <= args.warmup <= 1000 and 0 < args.idle_seconds <= 3600,
            "invalid bounded measurement durations")
    args.binary = args.binary.resolve()
    output = args.output or ROOT / "tests/results" / f"terminal-{args.kind}-safe-measure.json"
    report = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "kind": args.kind,
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "platform": platform.platform(),
              "python": platform.python_version(), "cycles": args.cycles, "warmup": args.warmup,
              "idleRequestedSeconds": args.idle_seconds, "sampleIntervalMs": 50,
              "syntheticOnly": True, "desktopUsed": False, "liveWrites": False,
              "acceptanceRun": args.cycles >= 1000 and args.idle_seconds >= 60,
              "limits": {"warmGrowthKiB": 4096, "idlePercentOfOneCore": .5, "terminalHeapBytes": LIMIT},
              "allocationAccounting": "64MiB terminal heap ceiling is separate from16MiB fixed backend/HTTP reservation; LinuxRSS/PSS sample the whole process",
              "rssAbsoluteLimit": None, "pssAbsoluteLimit": None,
              "fixtureManifestSha256": hashlib.sha256((FIXTURES / "manifest.json").read_bytes()).hexdigest()}
    try:
        report.update(read_build_info(args.binary, "safe"))
        with tempfile.TemporaryDirectory(prefix=f"omagma-terminal-{args.kind}-measure-") as directory:
            measure(args, report, Path(directory))
        report["passed"] = all(report["checks"].values())
    except Exception as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ["passed", "acceptanceRun", "process", "quiet", "allocator", "error"]}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
