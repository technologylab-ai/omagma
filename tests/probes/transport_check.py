#!/usr/bin/env python3
"""Exercise bounded Zig HTTP requests against a synthetic loopback server."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import sys
import time

from transport_server import server

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from build_info import build_mode, read_build_info


def run_probe(argv, timeout=15):
    """Separate post-exec /proc samples from conservative wait4 spawn accounting."""
    out_read, out_write = os.pipe()
    err_read, err_write = os.pipe()
    actions = [(os.POSIX_SPAWN_DUP2, out_write, 1), (os.POSIX_SPAWN_DUP2, err_write, 2)]
    actions += [(os.POSIX_SPAWN_CLOSE, fd) for fd in [out_read, out_write, err_read, err_write]]
    pid = os.posix_spawn(argv[0], argv, os.environ.copy(), file_actions=actions)
    os.close(out_write)
    os.close(err_write)
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    for fd, name in [(out_read, "stdout"), (err_read, "stderr")]:
        os.set_blocking(fd, False)
        selector.register(fd, selectors.EVENT_READ, name)
    deadline = time.monotonic() + timeout
    receipt = None
    rss_samples = []
    def sample():
        try:
            # Exclude the inherited pre-exec Python address space.
            if Path(os.readlink(f"/proc/{pid}/exe")).resolve() != Path(argv[0]).resolve():
                return
            values = {}
            for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                key, _, value = line.partition(":")
                if key in {"VmRSS", "VmHWM", "Threads"}:
                    values[key] = int(value.split()[0])
            if "VmRSS" in values:
                rss_samples.append(values)
        except (OSError, ValueError):
            pass
    try:
        while selector.get_map():
            sample()
            if time.monotonic() >= deadline:
                raise AssertionError("external harness deadline expired; internal cancellation was not proven")
            for key, _ in selector.select(0.001):
                chunk = os.read(key.fd, 16384)
                if not chunk:
                    selector.unregister(key.fd)
                else:
                    buffers[key.data].extend(chunk)
                    if len(buffers[key.data]) > 16384:
                        raise AssertionError("probe diagnostics exceeded bounded output")
        while receipt is None:
            child, status, usage = os.wait4(pid, os.WNOHANG)
            if child:
                receipt = (os.waitstatus_to_exitcode(status), usage)
                break
            if time.monotonic() >= deadline:
                raise AssertionError("external harness deadline expired after output closed")
            time.sleep(0.005)
        return {"stdout": bytes(buffers["stdout"]), "stderr": bytes(buffers["stderr"]),
                "exitCode": receipt[0], "wait4MaxRssKiB": receipt[1].ru_maxrss,
                "procObservedPeakRssKiB": max((item["VmRSS"] for item in rss_samples), default=None),
                "procObservedHwmRssKiB": max((item["VmHWM"] for item in rss_samples), default=None),
                "maxObservedThreads": max((item["Threads"] for item in rss_samples), default=None),
                "postExecProcSamples": len(rss_samples),
                "userCpuSeconds": receipt[1].ru_utime, "systemCpuSeconds": receipt[1].ru_stime}
    finally:
        selector.close()
        os.close(out_read)
        os.close(err_read)
        if receipt is None:
            os.kill(pid, signal.SIGKILL)
            os.wait4(pid, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--build-mode", type=build_mode, choices=["debug", "safe"], default="debug")
    parser.add_argument("--https", action="store_true", help="Also run credential-free Google HTTPS profile request (expected401)")
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    args.output = args.output or ROOT / f"tests/results/zig017-transport-{args.build_mode}.json"
    result = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "syntheticOnly": True, "requestedBuildMode": args.build_mode,
              "memoryAccounting": "wait4 peak may include inherited Python spawn footprint; /proc samples are checked post-exec, sampled every1ms and can miss short peaks",
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "checks": {}}
    try:
        result.update(read_build_info(args.binary, args.build_mode))
    except Exception as error:
        result.update(passed=False, error=str(error))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(f"FAIL build identity: {error}", flush=True)
        return 1
    with server() as peer:
        origin = f"http://127.0.0.1:{peer.server_port}"
        for path in ["/ok", "/chunk", "/bearer", "/bearer-missing", "/bearer-redirect", "/oversize", "/oversize-chunk", "/gzip", "/redirect", "/largeheader", "/hang", "/trickle"]:
            started = time.monotonic()
            requests_before = len(peer.requests)
            try:
                mode = "probe-http-bearer" if path in {"/bearer", "/bearer-redirect"} else "probe-http"
                process = run_probe([str(args.binary), mode, origin + path])
                if process["exitCode"] != 0 or process["stderr"]:
                    raise AssertionError("probe failed or emitted unexpected diagnostics")
                elapsed = time.monotonic() - started
                frames = process["stdout"].splitlines()
                if len(frames) != 1:
                    raise AssertionError("probe must output one bounded JSON result")
                frame = json.loads(frames[0])
                if frame["httpPeakBytes"] > 8 * 1024 * 1024:
                    raise AssertionError("HTTP allocator exceeded reserved workspace")
                if frame["bodyBytes"] > 524288:
                    raise AssertionError("body storage exceeded streaming cap")
                if path in {"/ok", "/chunk", "/bearer"}:
                    if not frame["ok"] or frame["status"] != 200 or frame["bodyBytes"] != 2:
                        raise AssertionError(f"valid synthetic response failed: {frame}")
                elif path == "/bearer-missing":
                    if not frame["ok"] or frame["status"] != 401:
                        raise AssertionError("synthetic peer did not reject a missing bearer")
                elif frame["ok"] or not frame.get("error"):
                    raise AssertionError(f"boundary response was accepted: {frame}")
                if path == "/redirect" and "/ok" in peer.requests[requests_before:]:
                    raise AssertionError("API transport followed redirect")
                if path == "/bearer-redirect" and "/bearer" in peer.requests[requests_before:]:
                    raise AssertionError("bearer transport followed redirect")
                if path in {"/hang", "/trickle"} and not 8 <= elapsed <= 12:
                    raise AssertionError(f"internal 10s deadline did not bound request: {elapsed:.3f}s")
                if path in {"/hang", "/trickle"} and frame.get("error") != "Timeout":
                    raise AssertionError("request did not report the internal deadline's Timeout result")
                result["checks"][path] = {"passed": True, "wallSeconds": round(elapsed, 4),
                                         **{key: value for key, value in process.items() if key not in {"stdout", "stderr"}}, **frame}
                print(f"PASS {path}: {elapsed:.3f}s", flush=True)
            except Exception as error:
                result["checks"][path] = {"passed": False, "wallSeconds": round(time.monotonic() - started, 4), "error": str(error)}
                print(f"FAIL {path}: {error}", flush=True)
        result["requestsObserved"] = peer.requests
    if args.https:
        try:
            process = run_probe([str(args.binary), "probe-https"])
            if process["exitCode"] != 0 or process["stderr"]:
                raise AssertionError("HTTPS probe failed or emitted unexpected diagnostics")
            frame = json.loads(process["stdout"])
            if not frame["ok"] or frame["status"] != 401:
                raise AssertionError(f"credential-free Google HTTPS did not return expected401: {frame}")
            if frame["bodyBytes"] > 524288 or frame["httpPeakBytes"] > 8 * 1024 * 1024:
                raise AssertionError("Google HTTPS probe exceeded storage budget")
            result["checks"]["google-credential-free-https"] = {"passed": True,
                **{key: value for key, value in process.items() if key not in {"stdout", "stderr"}}, **frame}
        except Exception as error:
            result["checks"]["google-credential-free-https"] = {"passed": False, "error": str(error)}
    result["passed"] = all(check["passed"] for check in result["checks"].values())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
