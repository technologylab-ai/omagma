#!/usr/bin/env python3
"""Additive Safe Markdown preview lifecycle/quiet gate, Linux or native Darwin.

Preserves the established 4MiB warm process growth, 0.5% quiet CPU and 64MiB
owned-heap limits. Original incoming-mail/navigation soaks remain separate.
Every account, draft and terminal is synthetic; no submission is performed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import tempfile
import time

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, require
from terminal_measure import LIMIT, allocator_receipt, cli_quiet_pump
from terminal_mouse import MouseTerminal, click, point
from terminal_mouse_screen import MouseScreen

SOURCE = ("# Markdown lifetime fixture\n\n**Strong** and *emphasis* with [link](https://example.test/lifecycle).\n\n"
          "- first\n  - nested\n- second\n\n| Name | Count |\n| :--- | ---: |\n| Fixture | 42 |\n\n"
          "```zig\nconst count = 42; // <literal>\n```\n\n"
          + "Bounded paragraph with escaped <technical> text and useful words.\n\n" * 128
          + "LIFETIME-TAIL")


def resources():
    if sys.platform == "darwin":
        from terminal_measure_macos import Sampler, quiet, sample
        from terminal_macos import DarwinTerminal
        before = sample(os.getpid())
        started = time.process_time()
        while time.process_time() - started < .05:
            pass
        python_cpu = time.process_time() - started
        native_cpu = (sample(os.getpid())["cpuNanoseconds"] - before["cpuNanoseconds"]) / 1e9
        require(abs(native_cpu - python_cpu) < .02, "native CPU unit/control mismatch")
        return sample, Sampler, quiet, DarwinTerminal, ("rssKiB", "footprintKiB")
    require(sys.platform.startswith("linux"), "resource gate requires Linux or native Darwin")
    from terminal_measure import Sampler, quiet, process_sample
    return process_sample, Sampler, quiet, MouseTerminal, ("rssKiB", "pssKiB")


def assert_preview(value, body, markdown):
    require(value["bodyText"] == body, "preview rewrote supplied source")
    if markdown:
        require("<strong>Strong</strong>" in value["bodyHtml"] and "<table" in value["bodyHtml"], "Markdown preview omitted semantics")
        require(value["plainText"].endswith(" 🌋") and value["bodyFormat"] == "markdown", "Markdown alternatives lost their format/footer")
    else:
        require(value["plainText"] == body and value.get("bodyHtml") is None and value["bodyFormat"] == "plain", "plain source was interpreted as Markdown")


def cli_cycle(client, index):
    account = ACCOUNTS[index % len(ACCOUNTS)]
    markdown = index % 2 == 0
    body = SOURCE + ("\nRevision A" if index % 4 < 2 else "\nRevision B")
    value = client.request("draft.preview", account, draft={"bodyText": body, "bodyFormat": "markdown" if markdown else "plain"})
    assert_preview(value, body, markdown)


def live_allocations(client):
    return {account: client.request("cache.stats", account)["allocatorUsedBytes"] for account in ACCOUNTS}


def normal(terminal):
    require(compose_mode(terminal), "normal transition requested outside actual Compose header")
    if "Body: INSERT" in terminal.text():
        terminal.send(b"\x1b")
        terminal.until(lambda: compose_mode(terminal) and "Body: INSERT" not in terminal.text())


def compose_mode(terminal):
    return "| Compose |" in terminal.screen.lines()[0] and "Subject:" in terminal.text()


def markdown_mode(terminal):
    return "MD · Body:" in terminal.text() and "[Plain Ctrl+T]" in terminal.text()


def plain_mode(terminal):
    return "Plain · Body:" in terminal.text() and "[Markdown Ctrl+T]" in terminal.text()


def source_edit(terminal, added):
    before = terminal.output_total
    terminal.send(b"x" if added else b"\x7f")
    terminal.until(lambda: terminal.output_total > before and
                   ("LIFETIME-TAILx" in terminal.text() if added else "LIFETIME-TAILx" not in terminal.text() and "LIFETIME-TAIL" in terminal.text()))


def open_draft(terminal):
    terminal.lifecycle_stage = "open retained draft"
    if not compose_mode(terminal):
        if "Markdown lifetime fixture" not in terminal.text():
            click(terminal, *point(terminal, "Drafts"))
            terminal.until(lambda: "Markdown lifetime fixture" in terminal.text())
        # A provisional list row can paint before its completed request is
        # consumed. Retry only while still outside compose, so Enter never
        # becomes input in a newly opened field.
        for _ in range(10):
            if compose_mode(terminal) and markdown_mode(terminal):
                break
            terminal.send(b"\r")
            terminal.gap(.1)
    terminal.until(lambda: compose_mode(terminal) and markdown_mode(terminal)
                   and "Protected recovery draft" not in terminal.text() and "Ctrl+S Review" in terminal.text())
    terminal.send(b"\t\t\t\ti")
    terminal.until(lambda: "Body: INSERT" in terminal.text() and "LIFETIME-TAIL" in terminal.text())


def close_draft(terminal):
    terminal.lifecycle_stage = "close retained draft"
    normal(terminal)
    require(compose_mode(terminal), "close attempted outside actual Compose mode")
    terminal.send(b"q")
    terminal.until(lambda: "Subject:" not in terminal.text() and "Markdown lifetime fixture" in terminal.text()
                   and "Working…" not in terminal.text())


def tui_cycle(terminal, index):
    terminal.lifecycle_stage = "replace source preview"
    source_edit(terminal, True)
    source_edit(terminal, False)
    terminal.lifecycle_stage = "switch source format"
    terminal.send(b"\x14")
    terminal.until(lambda: plain_mode(terminal))
    terminal.send(b"\x14")
    terminal.until(lambda: markdown_mode(terminal))
    normal(terminal)
    terminal.lifecycle_stage = "switch preview context"
    terminal.send(b"p")
    terminal.until(lambda: "Plain-text alternative" in terminal.text())
    terminal.send(b"p")
    terminal.until(lambda: "Outgoing preview" in terminal.text())
    if (index + 1) % 10 == 0:
        close_draft(terminal)
        open_draft(terminal)
    else:
        terminal.send(b"i")
        terminal.until(lambda: "Body: INSERT" in terminal.text())


def measure_workload(args, directory, report):
    sample, sampler_type, quiet, terminal_type, process_keys = resources()
    meter = directory / "allocator.json"
    rows = []
    report["cycleSamples"] = rows
    if args.kind == "cli":
        with Client(args.binary, directory / "cli", extra=("--metrics-file", str(meter))) as client:
            with sampler_type(client.process.pid) as sampler:
                for index in range(args.warmup):
                    cli_cycle(client, index)
                # Per-frame/job arenas must release all renderer allocations.
                baseline = live_allocations(client)
                report["liveAllocationBaselineBytes"] = baseline
                for index in range(args.cycles):
                    cli_cycle(client, args.warmup + index)
                    rows.append(sample(client.process.pid))
                    if (index + 1) % 100 == 0:
                        live = live_allocations(client)
                        report["liveAllocationFinalBytes"] = live
                        require(all(live[account] <= baseline[account] for account in ACCOUNTS), "preview source/format replacement retained live allocations above warm baseline")
                        print(f"Markdown CLI {index + 1}/{args.cycles}", flush=True)
                live = live_allocations(client)
                report["liveAllocationFinalBytes"] = live
                require(all(live[account] <= baseline[account] for account in ACCOUNTS), "preview lifecycle did not return at or below warm live allocation baseline")
                report["quiet"] = quiet(client.process, args.idle_seconds, lambda seconds: cli_quiet_pump(client, seconds))
                for account in ACCOUNTS:
                    stats = client.request("cache.stats", account)
                    require(stats["fixtureSends"] == 0 and not client.request("draft.list", account)["drafts"]
                            and not client.request("operation.list", account)["operations"], "preview gate created or submitted mail")
        require(client.process.returncode == 0 and not client.stderr, "CLI gate did not exit cleanly")
        report["noRetainedAllocationGrowth"] = True
        report["workload"] = "supplied-source Markdown/plain preview replacement across three accounts"
    else:
        home = directory / "tui"
        with Client(args.binary, home) as client:
            draft = client.request("draft.create", draft={"to": "peer@example.test", "subject": "Markdown lifetime fixture", "bodyText": SOURCE, "bodyFormat": "markdown"})
        terminal = terminal_type(args.binary, home, extra=("--metrics-file", str(meter)), history_limit=65536,
                                 columns=160, rows=40, screen_type=MouseScreen, environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
        try:
            terminal.until(lambda: "Ready" in terminal.text())
            open_draft(terminal)
            with sampler_type(terminal.process.pid) as sampler:
                for index in range(args.warmup):
                    tui_cycle(terminal, index)
                for index in range(args.cycles):
                    tui_cycle(terminal, args.warmup + index)
                    rows.append(sample(terminal.process.pid))
                    if (index + 1) % 100 == 0:
                        print(f"Markdown TUI {index + 1}/{args.cycles}", flush=True)
                close_draft(terminal)
                before_output = terminal.output_total
                report["quiet"] = quiet(terminal.process, args.idle_seconds, terminal.pump)
                report["quiet"]["outputBytesAdded"] = terminal.output_total - before_output
                require(report["quiet"]["outputBytesAdded"] == 0, "closed draft kept rendering during quiet interval")
            report["lifecycle"] = terminal.finish()
            with Client(args.binary, home) as client:
                retained = client.request("draft.read", draftId=draft["id"])
                require(retained["bodyText"] == SOURCE and retained["bodyFormat"] == "markdown", "edit/switch/close/reopen lifecycle changed retained source/format")
                require(len(client.request("draft.list")["drafts"]) == 1 and not client.request("operation.list")["operations"]
                        and client.request("cache.stats")["fixtureSends"] == 0, "lifecycle grew drafts or submitted mail")
        except Exception:
            report["failureCurrentCells"] = terminal.text().splitlines()
            report["failureStage"] = getattr(terminal, "lifecycle_stage", "initial readiness")
            report["failureProcessExitCode"] = terminal.process.poll()
            report["failureRecentOutput"] = bytes(terminal.output[-4096:]).decode("utf-8", "replace")
            raise
        finally:
            terminal.close()
        report["workload"] = "source edit/backspace, Markdown/plain, rendered/plain context, close/reopen every ten cycles"
    report["allocator"] = allocator_receipt(meter)
    quarter = max(1, len(rows) // 4)
    report["process"] = {"sampleCount": sampler.count, "metrics": {}}
    report["process"]["observedPeak"] = sampler.peak if sys.platform == "darwin" else sampler.peaks
    for key in process_keys:
        first = statistics.median(row[key] for row in rows[:quarter])
        last = statistics.median(row[key] for row in rows[-quarter:])
        report["process"]["metrics"][key] = {"earlyQuarterMedian": first, "lateQuarterMedian": last, "warmMedianGrowth": last - first}
        require(last - first <= 4096, "Markdown warm process growth exceeded established4MiB")
    require(report["allocator"]["rejectedAllocations"] == 0, "Markdown lifecycle rejected application allocations")
    require(report["quiet"]["percentOfOneCore"] < .5, "Markdown quiet CPU exceeded established0.5%of one core")


def measured(args, directory, report):
    try:
        measure_workload(args, directory, report)
    finally:
        # Retain the actual meter when a rendering/lifecycle/process oracle
        # fails; the temporary home is removed only after this preservation.
        meter = directory / "allocator.json"
        if meter.exists() and "allocator" not in report:
            report["allocatorAtExit"] = json.loads(meter.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=("cli", "tui"))
    parser.add_argument("--cycles", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=100)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    require(1 <= args.cycles <= 10000 and 0 <= args.warmup <= 1000 and 0 < args.idle_seconds <= 3600, "invalid bounded lifecycle durations")
    require(not args.output.exists(), "refusing previous lifecycle receipt overwrite")
    args.binary = args.binary.resolve()
    report = {"schemaVersion": 1, "suite": "terminal-markdown-lifecycle", "kind": args.kind,
              "platform": platform.platform(), "architecture": platform.machine(), **read_build_info(args.binary, "safe"),
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "syntheticOnly": True, "desktopUsed": False, "liveWrites": False,
              "cycles": args.cycles, "warmup": args.warmup, "idleRequestedSeconds": args.idle_seconds,
              "acceptanceRun": args.warmup >= 100 and args.cycles >= 1000 and args.idle_seconds >= 60, "sourceBytes": len(SOURCE.encode()),
              "limits": {"warmGrowthKiB": 4096, "idlePercentOfOneCore": .5, "terminalHeapBytes": LIMIT},
              "processMetricMeaning": "Darwin RSS/physical footprint; no PSS" if sys.platform == "darwin" else "Linux RSS/PSS; separate from owned allocations",
              "passed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="omagma-markdown-lifecycle-") as temporary:
            measured(args, Path(temporary), report)
        require(hashlib.sha256(args.binary.read_bytes()).hexdigest() == report["binarySha256"], "tested binary changed")
        report["passed"] = True
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        report["completedCycles"] = len(report.get("cycleSamples", []))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        args.output.chmod(0o600)
    print(json.dumps({key: report.get(key) for key in ("passed", "acceptanceRun", "completedCycles", "process", "quiet", "allocator", "error")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
