#!/usr/bin/env python3
"""Closed-popup timer/memory measurement; --live is explicit and logs no mail."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import time

from integration import Daemon, ROOT, proc_sample, require, validate_metrics
from measure import Sampler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--fixtures", action="store_true")
    mode.add_argument("--live", action="store_true")
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--account", default="work@example.com")
    parser.add_argument("--fixture-interval-ms", type=int, default=25)
    parser.add_argument("--jobs", type=int, default=1000)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    config = json.loads(args.config.read_text())
    seconds = config.get("refreshIntervalSeconds", 0)
    require(args.fixtures or type(seconds) is int and 60 <= seconds <= 86400, "live check requires an enabled background interval")
    require(args.jobs >= 4 and args.idle_seconds > 0 and 1 <= args.fixture_interval_ms <= 60000, "invalid measurement options")
    result = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "live": args.live,
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "intervalSeconds": seconds if args.live else args.fixture_interval_ms / 1000,
              "privacy": "Only counts, states and process metrics. No mail content, IDs, tokens or callback URLs. Popup remains closed; browser opening is dry-run.",
              "checks": {}}
    try:
        extra = ["--fixture-auto-refresh-ms", str(args.fixture_interval_ms), "--fixture-delay-ms", "2", "--fixture-rows", "30"] if args.fixtures else []
        with Daemon(args.binary, args.config, extra, fixture_mode=args.fixtures) as daemon:
            daemon.hello()
            with Sampler(daemon.process.pid) as sampler:
                def ready():
                    status = daemon.request("status")
                    if args.live:
                        return next(a for a in status["accounts"] if a["account"] == args.account)["state"] == "current" and status["metrics"]["activeJobs"] == 0 and status["metrics"]["pendingJobs"] == 0
                    return all(a["state"] == "current" for a in status["accounts"] if a["enabled"])
                daemon.until(ready, 40)
                initial = daemon.request("status")
                events = daemon.event_count
                rows = []
                peak_active = peak_pending = 0
                if args.fixtures:
                    start_jobs = initial["metrics"]["refreshJobs"]
                    deadline = time.monotonic() + max(30, args.jobs * args.fixture_interval_ms / 1000 + 30)
                    while True:
                        status = daemon.request("status")
                        validate_metrics(status["metrics"])
                        peak_active = max(peak_active, status["metrics"]["activeJobs"])
                        peak_pending = max(peak_pending, status["metrics"]["pendingJobs"])
                        rows.append(proc_sample(daemon.process.pid)["VmRSS"])
                        if status["metrics"]["refreshJobs"] - start_jobs >= args.jobs:
                            break
                        require(time.monotonic() < deadline, "background fixture jobs did not complete")
                        daemon.pump(.01)
                    quarter = max(1, len(rows) // 4)
                    growth = statistics.median(rows[-quarter:]) - statistics.median(rows[:quarter])
                    result["soak"] = {"refreshJobsAdded": status["metrics"]["refreshJobs"] - start_jobs,
                                      "warmMedianGrowthRssKiB": growth, "maxActive": peak_active, "maxPending": peak_pending,
                                      "retainedRows": sum(len(a["messages"]) for a in status["accounts"])}
                    result["checks"].update({"growthUnder2MiB": growth <= 2048, "oneWorker": peak_active <= 1,
                                              "boundedPending": peak_pending <= 3, "boundedRows": result["soak"]["retainedRows"] <= 90})
                else:
                    first = next(a for a in initial["accounts"] if a["account"] == args.account)
                    before = proc_sample(daemon.process.pid)
                    require(args.idle_seconds < seconds - 40, "quiet sample must fit between timer ticks")
                    quiet_until = time.monotonic() + args.idle_seconds
                    print("Initial closed-popup live fetch passed; measuring quiet CPU, then waiting for one real timer tick.", flush=True)
                    while time.monotonic() < quiet_until:
                        daemon.pump(.1)
                    after = proc_sample(daemon.process.pid)
                    quiet = daemon.request("status")
                    elapsed = after["monotonic"] - before["monotonic"]
                    cpu = (after["cpuTicks"] - before["cpuTicks"]) / os.sysconf("SC_CLK_TCK")
                    result["idle"] = {"seconds": round(elapsed, 3), "cpuSeconds": cpu,
                                      "percentOfOneCore": round(cpu / elapsed * 100, 6),
                                      "refreshJobsAdded": quiet["metrics"]["refreshJobs"] - initial["metrics"]["refreshJobs"]}
                    deadline = time.monotonic() + seconds + 40
                    while True:
                        status = daemon.request("status")
                        validate_metrics(status["metrics"])
                        latest = next(a for a in status["accounts"] if a["account"] == args.account)
                        peak_active = max(peak_active, status["metrics"]["activeJobs"])
                        peak_pending = max(peak_pending, status["metrics"]["pendingJobs"])
                        if latest["generation"] > first["generation"] and latest["state"] == "current" and latest["checkedAt"] > first["checkedAt"]:
                            break
                        require(time.monotonic() < deadline, "live closed-popup timer did not publish a successful internal replacement")
                        daemon.pump(1)
                    result["timer"] = {"successfulChecksAdded": 1, "checkSpacingSeconds": latest["checkedAt"] - first["checkedAt"],
                                       "rowsBefore": len(first["messages"]), "rowsAfter": len(latest["messages"]),
                                       "maxActive": peak_active, "maxPending": peak_pending}
                    result["checks"].update({"quietCpuUnderHalfPercent": result["idle"]["percentOfOneCore"] < .5,
                                              "quietNoJobs": result["idle"]["refreshJobsAdded"] == 0,
                                              "timerCadence": abs(result["timer"]["checkSpacingSeconds"] - seconds) < 35,
                                              "oneWorker": peak_active <= 1, "boundedPending": peak_pending <= 3,
                                              "boundedRows": len(latest["messages"]) <= 30})
                result["checks"]["closedNoSnapshotEvents"] = daemon.event_count == events
                result["checks"]["disabledAccountsUntouched"] = all(a["state"] == "unavailable" and a["messages"] == [] and a["checkedAt"] == 0 for a in status["accounts"] if not a["enabled"])
            result["process"] = {"observedPeakRssKiB": max(s["VmRSS"] for s in sampler.samples),
                                 "osHighWaterRssKiB": max(s["VmHWM"] for s in sampler.samples),
                                 "maxThreads": max(s["Threads"] for s in sampler.samples),
                                 "samplingIntervalMs": 5, "excludes": "Chrome and transient keyring helper processes"}
            result["checks"]["rssUnder64MiB"] = result["process"]["osHighWaterRssKiB"] <= 65536
            result["passed"] = all(result["checks"].values())
    except Exception as error:
        result["passed"] = False
        result["error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
