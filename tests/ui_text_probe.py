#!/usr/bin/env python3
"""Compare QV4 text-normalization temporaries, with no window/backend/mail."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CHARACTER_ARRAY = r'''
function utf8Length(text) {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) n++;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length
             && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) { n += 4; i++; }
    else n += 3;
  }
  return n;
}
function displayText(value, limit) {
  if (typeof value !== "string") return "";
  const source = value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ");
  const chunks = [];
  let bytes = 0;
  for (const c of source) {
    const code = c.codePointAt(0);
    const safe = code >= 0xd800 && code <= 0xdfff ? "\ufffd" : c;
    const size = utf8Length(safe);
    if (bytes + size > limit) break;
    chunks.push(safe); bytes += size;
  }
  return chunks.join("");
}
'''
INDEXED = r'''
function displayText(value, limit) {
  if (typeof value !== "string") return "";
  const source = value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ");
  let bytes = 0, end = 0, hasUnpaired = false;
  while (end < source.length) {
    const code = source.charCodeAt(end);
    let size = code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
    let step = 1, unpaired = false;
    if (code >= 0xd800 && code <= 0xdbff && end + 1 < source.length
        && source.charCodeAt(end + 1) >= 0xdc00 && source.charCodeAt(end + 1) <= 0xdfff) {
      size = 4; step = 2;
    } else if (code >= 0xd800 && code <= 0xdfff) unpaired = true;
    if (bytes + size > limit) break;
    bytes += size; end += step;
    hasUnpaired = hasUnpaired || unpaired;
  }
  const prefix = end === source.length ? source : source.slice(0, end);
  return hasUnpaired ? prefix.replace(/[\ud800-\udbff][\udc00-\udfff]|[\ud800-\udfff]/g,
      pair => pair.length === 2 ? pair : "\ufffd") : prefix;
}
'''


def memory(pid):
    values = {}
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if ":" in line:
            key, rest = line.split(":", 1)
            if rest.split() and rest.split()[0].isdigit():
                values[key] = int(rest.split()[0])
    return {key: values[key] for key in ["Rss", "Pss", "Private_Dirty"]}


def main():
    report = {"mode": "QV4 offscreen normalization only; 270 synthetic maximum-size display fields"}
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
    with tempfile.TemporaryDirectory(prefix="omagma-text-probe-") as temporary:
        for mode, function in [("characterArray", CHARACTER_ARRAY), ("indexedPrefix", INDEXED)]:
            code = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property var outputs: []
FUNCTION
  function exercise() {
    const results = []
    const value = "Synthetic 😀 " + "x".repeat(1024)
    for (let row = 0; row < 270; row++) results.push(displayText(value, row % 3 === 2 ? 1024 : 512))
    outputs = results
    return "done"
  }
  IpcHandler {
    target: "text-probe"
    function ready(): string { return "ready" }
    function exercise(): string { return root.exercise() }
    function collect(): void { gc() }
  }
}
'''.replace("FUNCTION", function)
            path = Path(temporary) / f"{mode}.qml"
            path.write_text(code)
            log_path = ROOT / "tests/results" / f"ui-text-{mode}.log"
            with log_path.open("w") as log:
                process = subprocess.Popen(["quickshell", "--path", str(path), "--no-color"],
                                           stdout=log, stderr=subprocess.STDOUT, env=env)
                try:
                    def call(method):
                        return subprocess.run(["quickshell", "ipc", "--pid", str(process.pid), "call", "text-probe", method],
                                              env=env, capture_output=True, text=True, timeout=30)
                    for _ in range(100):
                        if call("ready").stdout.strip() == "ready": break
                        time.sleep(.05)
                    call("collect"); time.sleep(.1)
                    result = {"beforeKiB": memory(process.pid)}
                    assert call("exercise").stdout.strip() == "done"
                    result["after270FieldsKiB"] = memory(process.pid)
                    call("collect"); time.sleep(.1)
                    result["afterCollectionKiB"] = memory(process.pid)
                    report[mode] = result
                finally:
                    process.terminate(); process.wait(timeout=5)
    target = ROOT / "tests/results/ui-text-probe.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__": main()
