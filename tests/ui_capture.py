#!/usr/bin/env python3
"""Capture the actual Quickshell popup with synthetic mail, entirely offscreen.

--publication supplies three connected fictional accounts and a 2x PNG suitable
for README/social sharing. It never reads a user's configuration or mailbox.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ADDRESSES = ["personal@example.com", "work@example.com", "optional@example.com"]

# Entirely invented display data; none is copied from a mailbox or person.
PUBLICATION_MAIL = [
    ("Cedar Studio", "Design review on Thursday", "The latest mockups are ready. Let's review the smaller details together.", True),
    ("Harbor Workshop", "October build notes", "A short summary of this month's improvements, fixes, and next steps.", True),
    ("Project Lantern", "Planning the next sprint", "The draft plan is ready for a quick review before we begin.", False),
    ("Northstar Tools", "Your workspace summary", "Here's a tidy overview of the team's activity this week.", False),
    ("Willow Collective", "A simpler checklist", "We trimmed the checklist so the important tasks are easier to spot.", True),
    ("Studio Orbit", "Notes from today's demo", "Thanks for the thoughtful feedback. The notes and sketches are attached.", False),
    ("Platform Notes", "A quieter notification workflow", "A few small changes can help keep the focus on useful updates.", True),
    ("Open Trail", "Community meetup details", "The next gathering includes short talks, questions, and time to chat.", False),
    ("Maple Desk", "Next week's office hours", "The new schedule is ready. Pick a time that works for you.", False),
]


def capture_social(image, output, env):
    """Render a small branded QML frame around the genuine popup capture."""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    image_url = json.dumps(image.resolve().as_uri())
    logo_url = json.dumps((ROOT / "assets/magma.svg").as_uri())
    qml = f'''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {{
  FloatingWindow {{
    implicitWidth: 800
    implicitHeight: 520
    visible: Quickshell.env("QT_QPA_PLATFORM") === "offscreen"
    color: "#000000"
    Rectangle {{
      id: card
      anchors.fill: parent
      color: "#000000"
      Image {{ id: logo; x: 30; y: 13; width: 24; height: 24; source: {logo_url} }}
      Text {{ x: 64; y: 12; text: "omagma"; color: "#e4e7ed"; font.family: "monospace"; font.pixelSize: 20; font.bold: true }}
      Text {{ x: 180; y: 18; text: "Gmail, one account at a time"; color: "#a2adbd"; font.family: "monospace"; font.pixelSize: 12 }}
      Image {{ id: preview; x: 30; y: 50; width: 740; height: 440; source: {image_url}; smooth: false; fillMode: Image.PreserveAspectFit }}
      Text {{ x: 30; y: 500; text: "Synthetic demo mail · Separate accounts · Read only"; color: "#a2adbd"; font.family: "monospace"; font.pixelSize: 10 }}
    }}
  }}
  IpcHandler {{
    target: "omagma-social-capture"
    function ready(): bool {{ return preview.status === Image.Ready && logo.status === Image.Ready }}
    function capture(path: string): void {{ card.grabToImage(function(result) {{ result.saveToFile(path) }}) }}
  }}
}}
'''
    log_path = ROOT / "tests/results/ui-capture-social.log"
    with tempfile.TemporaryDirectory(prefix="omagma-social-") as directory, log_path.open("w") as log:
        config = Path(directory) / "shell.qml"
        config.write_text(qml)
        process = subprocess.Popen(["quickshell", "--path", str(config), "--no-color"],
                                   env=env, stdout=log, stderr=subprocess.STDOUT)
        def call(method, *fields):
            return subprocess.check_output(["quickshell", "ipc", "--pid", str(process.pid), "call",
                                            "omagma-social-capture", method, *fields], env=env, text=True,
                                           stderr=subprocess.PIPE, timeout=5).strip()
        try:
            deadline = time.monotonic() + 10
            ready = False
            while time.monotonic() < deadline:
                assert process.poll() is None, "Social card QML stopped; inspect ui-capture-social.log"
                try:
                    ready = call("ready") == "true"
                    if ready:
                        break
                except subprocess.CalledProcessError:
                    pass
                time.sleep(.05)
            assert ready, "Social card images did not load"
            time.sleep(.1)
            call("capture", str(output.resolve()))
            deadline = time.monotonic() + 5
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            assert output.exists(), "Social card capture failed"
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    for warning in ("TypeError", "ReferenceError", "Failed to load configuration", "Binding loop", "Error decoding", "Cannot open"):
        assert warning not in log_path.read_text(), f"Social card warning: {warning}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--selected", action="store_true")
    parser.add_argument("--backend-fixtures", action="store_true")
    parser.add_argument("--publication", action="store_true")
    parser.add_argument("--social-output", type=Path)
    parser.add_argument("--font-base", type=int)
    parser.add_argument("--scale-factor", type=int, choices=(1, 2, 3))
    args = parser.parse_args()
    if args.publication and args.backend_fixtures:
        parser.error("--publication uses dedicated fictional data, not backend row fixtures")
    if args.social_output and not args.publication:
        parser.error("--social-output requires --publication")
    output = args.output or ROOT / ("docs/images/omagma.png" if args.publication else "tests/results/ui-compact.png")
    if args.social_output and args.social_output.resolve() == output.resolve():
        parser.error("the popup and social card require distinct output paths")
    font_base = args.font_base or (12 if args.publication else 9)
    scale_factor = args.scale_factor or (2 if args.publication else 1)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_SCALE_FACTOR=str(scale_factor),
               OMAGMA_TEST_BINARY=str(ROOT / "zig-out/bin/omagma"), OMAGMA_TEST_FONT_BASE=str(font_base))
    for key in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DISPLAY"):
        env.pop(key, None)
    if args.publication:
        env["OMAGMA_TEST_CONFIG"] = str(ROOT / "tests/fixtures/all-accounts.json")
    else:
        env.pop("OMAGMA_TEST_CONFIG", None)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    log_path = ROOT / "tests/results/ui-capture.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        process = subprocess.Popen(["quickshell", "--path", str(ROOT / "offscreen.qml"), "--no-color"],
                                   env=env, stdout=log, stderr=subprocess.STDOUT)

        def call(method, *fields):
            return subprocess.check_output(["quickshell", "ipc", "--pid", str(process.pid), "call", "omagma-test",
                                            method, *fields], env=env, text=True, stderr=subprocess.PIPE, timeout=5).strip()

        def until(predicate, seconds=10):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                assert process.poll() is None, "Quickshell stopped; inspect ui-capture.log"
                try:
                    state = json.loads(call("state"))
                    if predicate(state):
                        return state
                except (subprocess.CalledProcessError, json.JSONDecodeError):
                    pass
                time.sleep(.05)
            raise AssertionError("Capture UI condition timed out; inspect ui-capture.log")

        try:
            until(lambda state: state["daemon"] == "ready")
            call("open")
            until(lambda state: state["pending"] == 0)
            if args.publication:
                call("select", ADDRESSES[1])
                until(lambda state: state["selected"] == ADDRESSES[1] and state["pending"] == 0)
            now_ms = int(time.time() * 1000)
            if args.publication:
                messages = [{"id": f"demo-{index}", "threadId": f"demo-thread-{index}", "sender": sender,
                             "subject": subject, "snippet": snippet, "receivedAt": now_ms - index * 2700000,
                             "unread": unread} for index, (sender, subject, snippet, unread) in enumerate(PUBLICATION_MAIL)]
            else:
                messages = [{"id": f"shared{index}", "threadId": f"thread{index}",
                             "sender": ["Cedar Studio", "Harbor Workshop", "Project Lantern", "Willow Collective"][index % 4],
                             "subject": ["Weekly release notes and updates", "Planning next week's meeting",
                                         "Your workspace summary", "A short follow-up"][index % 4],
                             "snippet": "Synthetic preview for visual QA. Mail stays read-only, in its own account.",
                             "receivedAt": now_ms - index * 3600000, "unread": index % 2 == 0} for index in range(12)]
            if not args.backend_fixtures:
                for index, address in enumerate(ADDRESSES):
                    connected = args.publication or index < 2
                    snapshot = {"ev": "snapshot", "account": address, "enabled": connected, "required": index < 2,
                                "generation": 10000, "state": "current" if connected else "unavailable",
                                "checkedAt": now_ms // 1000 if connected else 0,
                                "unread": [5, 12, 3][index] if connected else None,
                                "partial": False, "error": "", "retryAt": 0,
                                "messages": messages if connected else []}
                    call("inject", json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
            if args.publication:
                captured_state = until(lambda state: len(state["accounts"]) == 3 and all(
                    account["state"] == "current" and account["rows"] == len(PUBLICATION_MAIL)
                    and account["generation"] == 10000 for account in state["accounts"]))
                assert [account["account"] for account in captured_state["accounts"]] == ADDRESSES
                assert captured_state["selected"] == ADDRESSES[1] and not captured_state["error"]
            if args.selected:
                call("selectMessage", "demo-0" if args.publication else "shared1" if args.backend_fixtures else "shared0")
            time.sleep(.3)
            call("capture", str(output.resolve()))
            deadline = time.monotonic() + 5
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            assert output.exists(), "Capture failed; inspect ui-capture.log"
            call("close")
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    log_text = log_path.read_text()
    for warning in ("TypeError", "ReferenceError", "Failed to load configuration", "Binding loop", "Cannot anchor",
                    "Error decoding", "Cannot open", "set multiple times"):
        assert warning not in log_text, f"Capture warning: {warning}; inspect {log_path}"
    width, height = struct.unpack(">II", output.read_bytes()[16:24])
    if args.social_output:
        capture_social(output, args.social_output, env)
    print(json.dumps({"image": str(output), "width": width, "height": height, "publication": args.publication,
                      "syntheticOnly": True, "offscreen": True, "scaleFactor": scale_factor}))


if __name__ == "__main__":
    main()
