#!/usr/bin/env python3
"""Isolate QV4 request-ledger storage with no native window or backend."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def memory(pid):
    values = {}
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if ":" in line:
            key, rest = line.split(":", 1)
            if rest.split() and rest.split()[0].isdigit():
                values[key] = int(rest.split()[0])
    return {key: values[key] for key in ["Rss", "Pss", "Private_Dirty"]}


def main():
    report = {"mode": "QV4 offscreen ledger only; no window/backend/mail"}
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
               QT_LOGGING_RULES="qt.qml.gc.statistics.debug=true;qt.qml.gc.allocatorStats.debug=true")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
    with tempfile.TemporaryDirectory(prefix="omagma-ledger-probe-") as temporary:
        for mode in ["numericMap", "boundedList"]:
            code = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property var pending: MODE === "numericMap" ? ({}) : []
  function exercise(count) {
    for (let id = 1; id <= count; id++) {
      if (MODE === "numericMap") {
        const requests = Object.assign({}, pending)
        requests[id] = { cmd: "visibility", account: "synthetic", deadline: Date.now() + 35000 }
        pending = requests
        const replies = Object.assign({}, pending)
        delete replies[id]
        pending = replies
      } else {
        const requests = pending.slice()
        requests.push({ id: id, cmd: "visibility", account: "synthetic", deadline: Date.now() + 35000 })
        pending = requests
        pending = pending.filter(entry => entry.id !== id)
      }
    }
    return "done"
  }
  IpcHandler {
    target: "ledger-probe"
    function ready(): string { return "ready" }
    function exercise(count: int): string { return root.exercise(count) }
    function collect(): void { gc() }
  }
}
'''.replace("MODE", json.dumps(mode))
            path = Path(temporary) / f"{mode}.qml"
            path.write_text(code)
            log_path = ROOT / "tests/results" / f"ui-ledger-{mode}.log"
            with log_path.open("w") as log:
                process = subprocess.Popen(["quickshell", "--path", str(path), "--no-color"],
                                           stdout=log, stderr=subprocess.STDOUT, env=env)
                try:
                    def call(method, *args):
                        return subprocess.run(["quickshell", "ipc", "--pid", str(process.pid), "call",
                                               "ledger-probe", method, *map(str, args)],
                                              env=env, capture_output=True, text=True, timeout=30)
                    for _ in range(100):
                        if call("ready").stdout.strip() == "ready":
                            break
                        time.sleep(.05)
                    call("collect")
                    time.sleep(.1)
                    result = {"beforeKiB": memory(process.pid)}
                    assert call("exercise", 2500).stdout.strip() == "done"
                    result["after2500KiB"] = memory(process.pid)
                    call("collect")
                    time.sleep(.1)
                    result["afterCollectionKiB"] = memory(process.pid)
                    report[mode] = result
                finally:
                    process.terminate()
                    process.wait(timeout=5)
    target = ROOT / "tests/results/ui-ledger-probe.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
