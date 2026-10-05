#!/usr/bin/env python3
"""Qualify the terminal POST boundary with an independent synthetic wire peer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_integration import no_core_dump, require
from probes.terminal_transport_server import BODY_LIMIT, REQUEST_BODY, SUCCESS_BODY, server

ROOT = Path(__file__).resolve().parents[1]


def run_probe(argv, directory):
    env = dict(os.environ, HOME=str(directory), TMPDIR=str(directory))
    for key in ["CONFIG", "CACHE", "DATA", "STATE"]:
        env[f"XDG_{key}_HOME"] = str(directory / key.lower())
    runtime = directory / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    env["XDG_RUNTIME_DIR"] = str(runtime)
    for key in ["DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"]:
        env.pop(key, None)
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                          cwd=directory, preexec_fn=no_core_dump) as child:
        selector = selectors.DefaultSelector()
        streams = {child.stdout: bytearray(), child.stderr: bytearray()}
        for stream in streams:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        deadline = time.monotonic() + 15
        try:
            while selector.get_map():
                require(time.monotonic() < deadline, "external 15s deadline fired; internal timeout was not proven")
                for key, _ in selector.select(.01):
                    data = os.read(key.fileobj.fileno(), 4096)
                    if data:
                        streams[key.fileobj].extend(data)
                        require(len(streams[key.fileobj]) <= 16384, "probe output exceeded bounded diagnostics")
                    else:
                        selector.unregister(key.fileobj)
            child.wait(timeout=max(.01, deadline - time.monotonic()))
            return {"exitCode": child.returncode, "stdout": bytes(streams[child.stdout]),
                    "stderr": bytes(streams[child.stderr])}
        finally:
            selector.close()
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)


def check_request(record):
    require(record["method"] == "POST", "terminal request changed HTTP method")
    for key, expected in [("Authorization", "Bearer synthetic-omagma-bearer"), ("Content-Type", "application/json"),
                          ("Accept-Encoding", "identity"), ("Content-Length", "131072")]:
        require(record["headers"].get_all(key, []) == [expected], f"wire {key} is missing, duplicated or incorrect")
    require(not record["headers"].get_all("Transfer-Encoding", []), "fixed request used an unexpected transfer encoding")
    require(record["body"] == REQUEST_BODY and len(record["body"]) == 131072, "wire JSON was truncated or changed")
    require(json.loads(record["body"]) == {"payload": "x" * 131058}, "wire JSON content differs from independent oracle")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    output = args.output or ROOT / "tests/results" / f"terminal-transport-{args.build_mode}.json"
    report = {**read_build_info(args.binary, args.build_mode), "syntheticOnly": True, "loopbackOnly": True,
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-terminal-wire-") as directory, server() as peer:
        origin = f"http://127.0.0.1:{peer.server_port}"
        for path in ["/ok", "/redirect", "/hang", "/trickle", "/oversize", "/oversize-chunk", "/request-oversize"]:
            receipt = {"path": path}
            started = time.monotonic()
            before_connections, before_requests = peer.connections, len(peer.requests)
            try:
                mode = "probe-terminal-http-oversize" if path == "/request-oversize" else "probe-terminal-http"
                process = run_probe([str(args.binary), mode, origin + path], Path(directory))
                elapsed = time.monotonic() - started
                require(process["exitCode"] == 0 and not process["stderr"], "terminal wire probe did not return clean structured output")
                require(len(process["stdout"].splitlines()) == 1, "terminal probe did not emit exactly one JSON frame")
                frame = json.loads(process["stdout"])
                require(0 <= frame["httpPeakBytes"] <= 8 * 1024**2 and 0 <= frame["bodyBytes"] <= BODY_LIMIT,
                        "terminal transport exceeded workspace or response cap")
                time.sleep(.05)  # Let an accepted connection become observable even without request headers.
                requests = peer.requests[before_requests:]
                connections = peer.connections - before_connections
                if path == "/request-oversize":
                    require(not frame["ok"] and frame["error"] == "FormTooLarge", "oversized outgoing JSON was not refused")
                    require(connections == 0 and not requests, "oversized outgoing JSON touched the network before refusal")
                else:
                    require(len(requests) == 1 and requests[0]["path"] == path and connections == 1,
                            "terminal request was retried, forwarded or omitted")
                    check_request(requests[0])
                    if path == "/ok":
                        require(frame["ok"] and frame["status"] == 200 and frame["bodyBytes"] == len(SUCCESS_BODY),
                                "valid response above the old bar cap was not fully received")
                    else:
                        expected = "RedirectRejected" if path == "/redirect" else "Timeout" if path in {"/hang", "/trickle"} else "ResponseTooLarge"
                        require(not frame["ok"] and frame["error"] == expected, "terminal response boundary reported an incorrect outcome")
                    if path in {"/hang", "/trickle"}:
                        require(8 <= elapsed <= 12 and 8000 <= frame["elapsedMs"] <= 12000,
                                "request did not stop at the internal 10s total deadline")
                receipt.update(passed=True, wallSeconds=round(elapsed, 4), acceptedConnections=connections,
                               requestsObserved=len(requests), requestBytes=0 if not requests else len(requests[0]["body"]),
                               requestSha256=None if not requests else hashlib.sha256(requests[0]["body"]).hexdigest(), **frame)
            except Exception as error:
                receipt.update(passed=False, error=f"{type(error).__name__}: {error}",
                               wallSeconds=round(time.monotonic() - started, 4))
            report["cases"].append(receipt)
            print(json.dumps(receipt), flush=True)
    report["passed"] = all(case["passed"] for case in report["cases"])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
