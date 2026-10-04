#!/usr/bin/env python3
"""Opt-in read-only Gmail acceptance. Receipts exclude mail content and secrets."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

from integration import Daemon, ROOT, proc_sample, require
from measure import Sampler


@contextmanager
def manual_config(config):
    # A separate process measures named-account/manual behavior. Preserve the
    # installed background cadence; disable only this temporary probe's timer.
    with tempfile.TemporaryDirectory(prefix="omagma-manual-acceptance-") as directory:
        path = Path(directory) / "config.json"
        probe = dict(config, refreshIntervalSeconds=0)
        path.write_text(json.dumps(probe))
        path.chmod(0o600)
        yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true")
    mode.add_argument("--fixtures", action="store_true")
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(args.idle_seconds > 0, "idle duration must be positive")
    args.binary = args.binary.resolve()
    config = json.loads(args.config.read_text())
    account = next(a for a in config["accounts"] if a["address"] == args.account)
    result = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "live": args.live, "account": args.account,
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "privacy": "No tokens, client secrets, callback URLs, message IDs, senders, subjects or snippets recorded. Browser opening is dry-run only.",
              "backgroundDisabledInTemporaryProbeConfig": True,
              "checks": {}, "refreshes": []}
    try:
        with manual_config(config) as probe_config, Daemon(args.binary, probe_config, fixture_mode=args.fixtures) as daemon:
            initial = daemon.hello()
            require(initial["metrics"]["refreshJobs"] == 0, "closed startup scheduled a mailbox job")
            with Sampler(daemon.process.pid) as sampler:
                for index in range(2):
                    before = daemon.snapshots[args.account]["generation"]
                    if index == 0:
                        reply = daemon.request("visibility", open=True, account=args.account)
                    else:
                        reply = daemon.request("refresh", account=args.account)
                    require(reply.get("ok") is True, "refresh request rejected")
                    daemon.until(lambda: daemon.snapshots[args.account]["generation"] > before
                                 and daemon.snapshots[args.account]["state"] in {"current", "stale", "disconnected", "unavailable"}, 35)
                    snapshot = daemon.snapshots[args.account]
                    # Error codes are local constants; never serialize a snapshot.
                    require(snapshot["state"] == "current", "Gmail refresh failed: " + snapshot.get("error", ""))
                    status = daemon.settle(timeout=35)
                    result["refreshes"].append({"rows": len(snapshot["messages"]),
                        "rowsWithSnippet": sum(bool(m["snippet"]) for m in snapshot["messages"]),
                        "rowsWithSender": sum(bool(m["sender"]) for m in snapshot["messages"]),
                        "rowsWithSubject": sum(bool(m["subject"]) for m in snapshot["messages"]),
                        "unread": snapshot["unread"], "checkedAt": snapshot["checkedAt"],
                        "partial": snapshot["partial"], "metrics": status["metrics"]})
                others = [s for s in status["accounts"] if s["account"] != args.account]
                result["checks"]["otherAccountsUntouched"] = all(s["messages"] == [] and s["checkedAt"] == 0 for s in others)
                opened = daemon.request("open", account=args.account, kind="inbox")
                result["checks"]["inboxProfileArgv"] = opened.get("ok") is True and opened["argv"][:2] == [config["chrome"], "--profile-directory=" + account["profile"]]
                if snapshot["messages"]:
                    opened = daemon.request("open", account=args.account, kind="message", message=snapshot["messages"][0]["id"])
                    result["checks"]["messageProfileArgv"] = opened.get("ok") is True and opened["argv"][:2] == [config["chrome"], "--profile-directory=" + account["profile"]]
                require(daemon.request("visibility", open=False, account=args.account).get("ok") is True, "close rejected")
                closed = daemon.settle(timeout=35)
                events = daemon.event_count
                before_idle = proc_sample(daemon.process.pid)
                deadline = time.monotonic() + args.idle_seconds
                print("Live read-only refreshes completed; measuring closed-popup idle.", flush=True)
                while time.monotonic() < deadline:
                    daemon.pump(min(0.1, max(0, deadline - time.monotonic())))
                after_idle = proc_sample(daemon.process.pid)
                after = daemon.request("status")
                elapsed = after_idle["monotonic"] - before_idle["monotonic"]
                cpu = (after_idle["cpuTicks"] - before_idle["cpuTicks"]) / os.sysconf("SC_CLK_TCK")
                result["idle"] = {"seconds": round(elapsed, 3), "cpuSeconds": cpu,
                    "percentOfOneCore": round(cpu / elapsed * 100, 6),
                    "refreshJobsAdded": after["metrics"]["refreshJobs"] - closed["metrics"]["refreshJobs"],
                    "snapshotEventsAdded": daemon.event_count - events}
                result["checks"].update({"closedNoJobs": result["idle"]["refreshJobsAdded"] == 0,
                    "closedNoEvents": result["idle"]["snapshotEventsAdded"] == 0,
                    "closedCpuUnderHalfPercent": result["idle"]["percentOfOneCore"] < 0.5,
                    "twoRefreshes": len(result["refreshes"]) == 2})
            result["process"] = {"observedPeakRssKiB": max(s["VmRSS"] for s in sampler.samples),
                "osHighWaterRssKiB": max(s["VmHWM"] for s in sampler.samples),
                "maxThreads": max(s["Threads"] for s in sampler.samples),
                "samplingIntervalMs": 5, "excludes": "Browser and transient keyring helper processes"}
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
