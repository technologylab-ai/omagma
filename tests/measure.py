#!/usr/bin/env python3
"""ReleaseSafe synthetic soak and Linux RSS/CPU evidence; never contacts Gmail."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import threading
import time

from integration import ACCOUNTS, CONTRACT, Daemon, REQUIRED, check_reply, proc_sample, require, validate_metrics

ROOT = Path(__file__).resolve().parents[1]


class Sampler:
    def __init__(self, pid):
        self.pid = pid
        self.samples = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            try:
                self.samples.append(proc_sample(self.pid))
            except (FileNotFoundError, ProcessLookupError):
                return
            self.stop.wait(0.005)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()


def cycle(daemon, address):
    check_reply(daemon.request("visibility", open=True, account=address))
    # An opening can schedule never/stale data. Settle first so an explicit
    # refresh below corresponds to one completed refresh lifetime.
    daemon.settle()
    generation = daemon.snapshots[address]["generation"]
    check_reply(daemon.request("refresh", account=address))
    daemon.current(address, generation)
    check_reply(daemon.request("visibility", open=False, account=address))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--config", type=Path, default=ROOT / "tests/fixtures/all-accounts.json")
    parser.add_argument("--fixture-rows", type=int, default=30)
    parser.add_argument("--cycles", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=100)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, default=ROOT / "tests/results/backend-releasesafe.json")
    args = parser.parse_args()
    require(args.cycles >= 1 and args.warmup >= 0 and args.idle_seconds > 0 and 0 <= args.fixture_rows <= 30, "invalid measurement durations/rows")
    args.binary = args.binary.resolve()
    result = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "buildMode": "ReleaseSafe (caller supplies binary)", "binary": str(args.binary),
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "platform": platform.platform(), "python": platform.python_version(),
              "syntheticOnly": True, "cycles": args.cycles, "warmup": args.warmup,
              "fixtureRowsPerAccount": args.fixture_rows,
              "idleRequestedSeconds": args.idle_seconds, "sampleIntervalMs": 5,
              "limits": {"rssKiB": 65536, "warmMedianGrowthKiB": 2048, "idlePercentOfOneCore": 0.5}}
    try:
        with Daemon(args.binary, args.config, ["--fixture-delay-ms", "2", "--fixture-rows", str(args.fixture_rows)]) as daemon:
            hello = daemon.hello()
            baseline = proc_sample(daemon.process.pid)
            enabled_accounts = [item["account"] for item in hello["accounts"] if item["enabled"]]
            require(enabled_accounts, "soak requires enabled synthetic account")
            result["enabledFixtureAccounts"] = enabled_accounts
            result["initialMetrics"] = hello["metrics"]
            print(f"backend pid={daemon.process.pid}; warming {args.warmup} cycles", flush=True)
            with Sampler(daemon.process.pid) as sampler:
                for index in range(args.warmup):
                    cycle(daemon, enabled_accounts[index % len(enabled_accounts)])
                warm = daemon.settle()
                baseline_jobs = warm["metrics"]["refreshJobs"]
                result["warmMetrics"] = warm["metrics"]
                rows = []
                peak_metrics = dict(warm["metrics"])
                started = time.monotonic()
                for index in range(args.cycles):
                    cycle(daemon, enabled_accounts[index % len(enabled_accounts)])
                    row = proc_sample(daemon.process.pid)
                    row["cycle"] = index + 1
                    rows.append(row)
                    if index % 10 == 0 or index == args.cycles - 1:
                        metrics = daemon.settle()["metrics"]
                        validate_metrics(metrics)
                        for key in peak_metrics:
                            if type(metrics.get(key)) is int:
                                peak_metrics[key] = max(peak_metrics[key], metrics[key])
                    if (index + 1) % 100 == 0:
                        print(f"completed {index + 1}/{args.cycles}; RSS={row['VmRSS']} KiB", flush=True)
                result["soakSeconds"] = round(time.monotonic() - started, 4)
                final_status = daemon.settle()
                result["completedRefreshJobs"] = final_status["metrics"]["refreshJobs"] - baseline_jobs
                result["popupOpenCloseCycles"] = args.cycles
                result["metricHighWater"] = peak_metrics
                result["finalMetrics"] = final_status["metrics"]
                result["rowsAtEnd"] = {item["account"]: len(item["messages"]) for item in final_status["accounts"]}
                before_idle = proc_sample(daemon.process.pid)
                events_before = daemon.event_count
                print(f"closed-popup idle sample: {args.idle_seconds:g}s", flush=True)
                deadline = time.monotonic() + args.idle_seconds
                while time.monotonic() < deadline:
                    # Drain unsolicited events while measuring: no protocol command
                    # is issued during the quiet CPU window.
                    daemon.pump(min(0.25, max(0, deadline - time.monotonic())))
                after_idle = proc_sample(daemon.process.pid)
                idle_seconds = after_idle["monotonic"] - before_idle["monotonic"]
                cpu_seconds = (after_idle["cpuTicks"] - before_idle["cpuTicks"]) / os.sysconf("SC_CLK_TCK")
                cpu_percent = cpu_seconds / idle_seconds * 100
                after_status = daemon.request("status")
                result["idle"] = {"elapsedSeconds": round(idle_seconds, 4), "cpuSeconds": cpu_seconds,
                                  "percentOfOneCore": round(cpu_percent, 6), "threads": after_idle["Threads"],
                                  "rssKiB": after_idle["VmRSS"], "unsolicitedSnapshotEvents": daemon.event_count - events_before,
                                  "refreshJobsAdded": after_status["metrics"]["refreshJobs"] - final_status["metrics"]["refreshJobs"]}
            rss = [row["VmRSS"] for row in rows]
            quarter = max(1, len(rss) // 4)
            early = statistics.median(rss[:quarter])
            late = statistics.median(rss[-quarter:])
            result["process"] = {"coldRssKiB": baseline["VmRSS"], "warmEarlyMedianRssKiB": early,
                                 "warmLateMedianRssKiB": late, "warmMedianGrowthKiB": late - early,
                                 "soakMinRssKiB": min(rss), "soakMaxRssKiB": max(rss),
                                 "observedPeakRssKiB": max(row["VmRSS"] for row in sampler.samples),
                                 "osHighWaterRssKiB": max(row["VmHWM"] for row in sampler.samples),
                                 "coldThreads": baseline["Threads"], "maxThreads": max(row["Threads"] for row in sampler.samples),
                                 "rssIncreaseFromHelloKiB": late - baseline["VmRSS"],
                                 "sampleCount": len(sampler.samples)}
            result["cycleSamples"] = [{"cycle": row["cycle"], "rssKiB": row["VmRSS"], "threads": row["Threads"]} for row in rows]
            # Full acceptance requires all specified cycles and the quiet 60s window.
            result["acceptanceRun"] = args.cycles >= 1000 and args.idle_seconds >= 60
            result["checks"] = {
                "refreshLifetimesCompleted": result["completedRefreshJobs"] >= args.cycles,
                "rssUnder64MiB": result["process"]["osHighWaterRssKiB"] <= 65536,
                "warmRssPlateau": late - early <= 2048,
                "idleCpuUnderHalfPercent": cpu_percent < 0.5,
                "closedNoMailboxJobs": result["idle"]["refreshJobsAdded"] == 0,
                "closedNoSnapshotEvents": result["idle"]["unsolicitedSnapshotEvents"] == 0,
                "boundedRetainedRows": sum(result["rowsAtEnd"].values()) <= 90,
                "requestedCapacityRetained": all(result["rowsAtEnd"][address] == args.fixture_rows for address in enabled_accounts),
            }
            result["passed"] = all(result["checks"].values())
    except Exception as error:
        result["passed"] = False
        result["error"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ["passed", "acceptanceRun", "process", "idle", "error"]}, indent=2), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
