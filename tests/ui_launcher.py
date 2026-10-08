#!/usr/bin/env python3
"""Small offscreen fixture check for the actual bar Open TUI button; no soaks."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(binary):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", OMAGMA_TEST_BINARY=str(binary), OMAGMA_TEST_CONFIG="")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
    with tempfile.TemporaryDirectory(prefix="omagma-bar-launcher-") as directory:
        with (Path(directory) / "offscreen.log").open("w+") as log:
            process = subprocess.Popen(["quickshell", "--path", str(ROOT / "offscreen.qml"), "--no-color"],
                                       stdout=log, stderr=subprocess.STDOUT, env=env)
            try:
                def call(method):
                    result = subprocess.run(["quickshell", "ipc", "--pid", str(process.pid), "call", "omagma-test", method],
                                            env=env, text=True, capture_output=True, timeout=5)
                    assert result.returncode == 0, result.stderr
                    return result.stdout.strip()

                def until(predicate):
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        assert process.poll() is None, "offscreen shell failed"
                        try:
                            state = json.loads(call("state"))
                            if predicate(state):
                                return state
                        except (AssertionError, json.JSONDecodeError):
                            pass
                        time.sleep(.05)
                    raise AssertionError("bar launcher condition timed out")

                until(lambda state: state["daemon"] == "ready")
                call("open")
                before = until(lambda state: state["contentAlive"] and state["layout"] is not None
                               and state["retainedRows"] > 0 and state["pending"] == 0)
                bounds = before["layout"]
                assert bounds["tuiWidth"] > 0 and bounds["tuiHeight"] > 0
                assert 0 <= bounds["tuiX"] < bounds["width"] - bounds["tuiWidth"]
                assert 0 <= bounds["tuiY"] < bounds["height"] - bounds["tuiHeight"]
                # The fixture service is dry-run: activation must close the popup
                # while leaving the read-only daemon and its snapshot untouched.
                call("tui")
                after = until(lambda state: not state["opened"] and not state["contentAlive"])
                assert after["backendPid"] == before["backendPid"]
                assert after["selected"] == before["selected"]
                assert after["retainedRows"] == before["retainedRows"]
                assert after["daemon"] == "ready" and not after["error"]
                print("PASS actual Open TUI button: visible offscreen, popup closes, read-only backend/account snapshot preserved")
            except Exception:
                log.seek(0)
                print(log.read())
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    run(parser.parse_args().binary.resolve())
