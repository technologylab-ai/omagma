#!/usr/bin/env python3
"""Synthetic Quickshell offscreen lifecycle/PSS acceptance harness; not a runtime helper.

Requires Quickshell and a safe omagma. Forces the offscreen Qt platform.
Uses only --fixtures --dry-run-open. Never edits installed shell configuration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from build_info import read_build_info

ROOT = Path(__file__).resolve().parents[1]
ADDRESSES = ["personal@example.com", "work@example.com", "optional@example.com"]


def memory(pid):
    values = {}
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if ":" in line:
            key, rest = line.split(":", 1)
            fields = rest.split()
            if fields and fields[0].isdigit():
                values[key] = int(fields[0])
    return {"rssKiB": values["Rss"], "pssKiB": values["Pss"],
            "privateKiB": values.get("Private_Clean", 0) + values.get("Private_Dirty", 0),
            "pssAnonKiB": values.get("Pss_Anon", 0), "pssFileKiB": values.get("Pss_File", 0)}


def cpu_ticks(pid):
    # comm can contain spaces and parentheses; fields after its final ')' are
    # stat fields 3 onward, making utime/stime offsets 11 and 12.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--font-base", type=int, default=9)
    parser.add_argument("--cycles", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=200)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, default=ROOT / "tests/results/zig017-ui-offscreen.json")
    args = parser.parse_args()
    assert args.binary.is_file(), "Build the safe Zig fixture backend first"
    backend_build = read_build_info(args.binary, "safe")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"quickshell": subprocess.check_output(["quickshell", "--version"], text=True).strip(),
              "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "cycles": args.cycles,
              "warmup": args.warmup, "fontBase": args.font_base, "mode": "Qt offscreen fixture lifecycle, dry-run browser opening", "compositorVerified": False,
              "baselineSamples": [], "warmupSamples": [], "soakSamples": [],
              "sourceSha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ["Model.mjs", "Service.qml", "qml/MailView.qml", "qml/MailButton.qml", "qml/QuickPanel.qml", "qml/OffscreenShell.qml", "qml/OffscreenBaseline.qml", "tests/ui_gui.py"]},
              "backendSha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), **backend_build}
    env = dict(os.environ, OMAGMA_TEST_BINARY=str(args.binary.resolve()), QT_QPA_PLATFORM="offscreen", OMAGMA_TEST_FONT_BASE=str(args.font_base))
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
    processes = []
    try:
        baseline_log = open(args.output.with_suffix(".baseline.log"), "w")
        baseline = subprocess.Popen(["quickshell", "--path", str(ROOT / "offscreen-baseline.qml"), "--no-color"],
                                    stdout=baseline_log, stderr=subprocess.STDOUT, env=env)
        processes.append(baseline)
        time.sleep(3)
        assert baseline.poll() is None, "Quickshell baseline did not load"
        for _ in range(5):
            report["baselineSamples"].append(memory(baseline.pid))
            time.sleep(.2)
        stop(baseline)
        baseline_log.close()

        gui_log = open(args.output.with_suffix(".gui.log"), "w")
        gui = subprocess.Popen(["quickshell", "--path", str(ROOT / "offscreen.qml"), "--no-color"],
                               stdout=gui_log, stderr=subprocess.STDOUT, env=env)
        processes.append(gui)

        def call(method, *params):
            try:
                result = subprocess.run(["quickshell", "ipc", "--pid", str(gui.pid), "call", "omagma-test",
                                         method, *[str(p) for p in params]], capture_output=True, text=True, timeout=5, env=env)
            except subprocess.TimeoutExpired:
                raise AssertionError(f"Offscreen IPC {method} did not finish within 5 seconds") from None
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()

        def state():
            return json.loads(call("state"))

        def until(predicate, seconds=15):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                assert gui.poll() is None, "Quickshell stopped; inspect GUI log"
                try:
                    value = state()
                    if predicate(value):
                        return value
                except (json.JSONDecodeError, AssertionError):
                    pass
                time.sleep(.05)
            raise AssertionError("UI condition timed out")

        ready = until(lambda s: s["daemon"] == "ready")
        assert ready["selected"] == ADDRESSES[0]
        call("open")
        until(lambda s: s["accounts"][0]["state"] == "current")
        call("select", ADDRESSES[1])
        tech = until(lambda s: s["accounts"][1]["state"] == "current")
        assert tech["selected"] == ADDRESSES[1]
        call("close")
        closed = until(lambda s: not s["contentAlive"] and s["pending"] == 0)
        assert closed["selected"] == ADDRESSES[1]
        call("open")
        assert state()["selected"] == ADDRESSES[1]
        call("select", ADDRESSES[2])
        assert state()["accounts"][2]["state"] == "unavailable"
        call("select", ADDRESSES[1])
        # All browser operations go through the Zig validator; dry-run mode
        # proves the UI wiring while ensuring Chrome is never launched.
        call("inbox")
        until(lambda s: not s["opened"])
        call("open")
        call("message")
        until(lambda s: not s["opened"])
        call("open")
        call("restart")
        restarted = until(lambda s: s["daemon"] == "ready" and s["pending"] == 0)
        assert restarted["selected"] == ADDRESSES[1]
        report["restart"] = restarted

        def snapshot(address, index, generation=100000):
            return {"ev": "snapshot", "account": address, "enabled": index < 2, "required": index < 2,
                    "generation": generation, "state": "current", "checkedAt": int(time.time()),
                    "unread": [17, 42, 3][index], "partial": False, "error": "", "retryAt": 0,
                    "messages": [{"id": f"shared-{n}", "threadId": f"shared-thread-{n}",
                                  "sender": (address + " · synthetic sender " + "s" * 512)[:512],
                                  "subject": "<b>Literal HTML mail text</b> " + "x" * 475,
                                  "snippet": "Synthetic " + address + " snippet 😀 " + "z" * 1000,
                                  "receivedAt": int(time.time() * 1000) - n * 60000,
                                  "unread": n % 2 == 0} for n in range(30)]}

        with tempfile.TemporaryDirectory(prefix="omagmail-ui-fixtures-") as fixture_dir:
            def inject(value):
                loaded = state()["fixtureLoads"]
                path = Path(fixture_dir) / f"snapshot-{loaded}.json"
                path.write_text(json.dumps(value, ensure_ascii=False))
                call("injectFile", str(path))
                until(lambda s: s["fixtureLoads"] > loaded)

            for index, address in enumerate(ADDRESSES):
                inject(snapshot(address, index))
            full = state()
            assert full["retainedRows"] == 90 and full["maxRows"] == 90
            assert full["contentAlive"] and full["creations"] > 0, "Popup content failed to instantiate"
            bounds = full["layout"]
            assert bounds["closeWidth"] > 0 and bounds["closeHeight"] > 0
            assert bounds["closeX"] >= 0 and bounds["closeX"] + bounds["closeWidth"] <= bounds["width"] + 1, bounds
            assert bounds["closeY"] >= 0 and bounds["closeY"] + bounds["closeHeight"] <= bounds["height"] + 1, bounds
            report["headerBounds"] = bounds
            call("selectMessage", "shared-0")
            assert state()["selectedMessageId"] == "shared-0"
            call("moveSelection", 1)
            assert state()["selectedMessageId"] == "shared-1"
            call("moveSelection", -1)
            assert state()["selectedMessageId"] == "shared-0"
            # Stale replies and malformed over-limit snapshots cannot replace rows.
            older = snapshot(ADDRESSES[1], 1, 2)
            older["messages"] = []
            inject(older)
            assert state()["accounts"][1]["rows"] == 30
            too_many = snapshot(ADDRESSES[1], 1, 100001)
            too_many["messages"].append(too_many["messages"][0])
            inject(too_many)
            assert state()["accounts"][1]["rows"] == 30
        call("refresh")  # clear the test's invalid-frame status, without live I/O
        until(lambda s: s["pending"] == 0)
        report["keyboardEscape"] = "Not tested offscreen; no compositor input is sent"
        call("close")
        until(lambda s: not s["contentAlive"] and s["pending"] == 0)

        def soak(count, key):
            call("soak", count)
            deadline = time.monotonic() + max(30, count * .12)
            last_cycles = -1
            while time.monotonic() < deadline:
                value = state()
                sample = {"cycles": value["cycles"], "opened": value["opened"], **memory(gui.pid)}
                report[key].append(sample)
                assert value["retainedRows"] <= 90 and value["pending"] <= 64
                if value["cycles"] >= count:
                    assert not value["contentAlive"]
                    return value
                if value["cycles"] // 200 != last_cycles // 200:
                    print(f"{key}: {value['cycles']}/{count}, PSS {sample['pssKiB']} KiB", flush=True)
                last_cycles = value["cycles"]
                time.sleep(1)
            raise AssertionError("popup soak timed out")

        soak(args.warmup, "warmupSamples")
        time.sleep(3)
        report["afterWarmup"] = memory(gui.pid)
        final = soak(args.cycles, "soakSamples")
        time.sleep(3)
        report["afterSoak"] = memory(gui.pid)
        final = until(lambda s: s["pending"] == 0)
        assert final["creations"] == final["destructions"] and not final["contentAlive"]
        assert final["creations"] >= args.cycles + args.warmup, "Soak must create actual popup views"
        report["finalState"] = final
        report["baselinePssKiB"] = sum(v["pssKiB"] for v in report["baselineSamples"]) // len(report["baselineSamples"])
        report["incrementalClosedPssKiB"] = report["afterSoak"]["pssKiB"] - report["baselinePssKiB"]
        report["soakGrowthKiB"] = report["afterSoak"]["pssKiB"] - report["afterWarmup"]["pssKiB"]
        # Record allocator-owned private memory separately from file-backed
        # proportional shares, which change when unrelated Qt processes exit.
        # These add evidence; the existing PSS acceptance gates stay intact.
        baseline_private = sum(v["privateKiB"] for v in report["baselineSamples"]) // len(report["baselineSamples"])
        report["incrementalClosedPrivateKiB"] = report["afterSoak"]["privateKiB"] - baseline_private
        report["soakPrivateGrowthKiB"] = report["afterSoak"]["privateKiB"] - report["afterWarmup"]["privateKiB"]
        report["soakPssFileGrowthKiB"] = report["afterSoak"]["pssFileKiB"] - report["afterWarmup"]["pssFileKiB"]
        assert report["incrementalClosedPssKiB"] <= 20 * 1024, report
        # 2 MiB permits ordinary Qt/allocator page-granularity fluctuations.
        assert report["soakGrowthKiB"] <= 2 * 1024, report
        print("offscreen lifecycle soak complete; sampling closed-popup CPU", flush=True)
        backend_pid = int(final["backendPid"])
        gui_before, backend_before = cpu_ticks(gui.pid), cpu_ticks(backend_pid)
        start = time.monotonic()
        for _ in range(int(args.idle_seconds)):
            time.sleep(1)
        elapsed = time.monotonic() - start
        hz = os.sysconf("SC_CLK_TCK")
        report["idleSeconds"] = elapsed
        report["idleGuiCpuPercent"] = (cpu_ticks(gui.pid) - gui_before) / hz / elapsed * 100
        report["idleBackendCpuPercent"] = (cpu_ticks(backend_pid) - backend_before) / hz / elapsed * 100
        report["idleGenerationUnchanged"] = state()["accounts"] == final["accounts"]
        assert report["idleGenerationUnchanged"]
        assert report["idleGuiCpuPercent"] < .5 and report["idleBackendCpuPercent"] < .5
        stop(gui)
        gui_log.close()
        log = args.output.with_suffix(".gui.log").read_text()
        # Dormant qs.Ui scanner warnings are expected in the standalone config.
        assert all(word not in log for word in ["TypeError", "ReferenceError", "Failed to load configuration",
                   "unavailable", "set multiple times", "Binding loop", "Cannot anchor"]), log
        report["passed"] = True
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: report[key] for key in ["passed", "baselinePssKiB", "incrementalClosedPssKiB",
              "soakGrowthKiB", "idleGuiCpuPercent", "idleBackendCpuPercent"]}), flush=True)
    finally:
        for process in processes:
            stop(process)
        if not report.get("passed"):
            args.output.with_suffix(".failed.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
