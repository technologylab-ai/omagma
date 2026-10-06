#!/usr/bin/env python3
"""Capture real fictional TUI output for publication without desktop windows.

Requires Quickshell, ImageMagick and a root-coordinated runtime window. The
renderer paints the actual current PTY cells and SGR styles, never a UI mockup.
All mail, accounts, preferences and provider checkpoints are temporary fixtures.
"""
from __future__ import annotations

import argparse
import base64
import copy
import html
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from probes.cache_refresh_fixture import repage
from terminal_cache import ProviderFixture
from terminal_html import screen_capture
from terminal_html_screen import HtmlScreen
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal
from terminal_reader import reader_contains

SUBJECT = "Omagma smoke test: a very small eruption 🌋"
SMOKE = (
    "Hello Morgan,\n\n"
    "Omagma has evolved from a tiny volcano in the bar to a tiny volcano that sends mail 🌋.\n\n"
    "The smoke is metaphorical. Your inbox is not on fire.\n\n"
    "Meanwhile, a 2 GB Gmail tab insists it was always lightweight.\n\n"
    "Magma regards,\nYour suspiciously productive volcano\n"
)
SMOKE_HTML = (
    "<html><body><p>Hello Morgan,</p>"
    "<p>Omagma has evolved from a tiny volcano in the bar to a tiny volcano that "
    "<strong>sends mail</strong> 🌋.</p>"
    "<p>The smoke is metaphorical. Your inbox is <strong>not on fire</strong>.</p>"
    "<p>Meanwhile, a <strong>2 GB Gmail tab</strong> insists it was always lightweight.</p>"
    "<p>Magma regards,<br><em>Your suspiciously productive volcano</em></p></body></html>"
)
MAIL = (
    ("Omagma Volcano", SUBJECT, "The smoke is metaphorical. Your inbox is not on fire. 🌋", True),
    ("Cedar Studio", "A smaller inbox, a calmer morning ☕", "Three tiny improvements. One noticeably quieter morning.", True),
    ("Morgan", "Friday's launch checklist 🚀", "The last few details are ready. Let's make the landing smooth.", False),
    ("Harbor Workshop", "Design review: keep the good bits", "The clean layout works. The giant buttons can take a holiday.", True),
    ("Project Lantern", "Notes from the demo ✨", "A reader, a terminal, and a suspiciously useful little volcano.", False),
    ("Willow Collective", "Re: A very reasonable memory budget", "Turns out mail can leave room for the rest of your computer.", True),
    ("Northstar Tools", "Your October workspace summary", "A tidy overview of what changed, without fifteen browser tabs.", False),
    ("Open Trail", "Community meetup: bring your questions", "Short talks, good coffee, and a little time to catch up.", False),
    ("Studio Orbit", "The subject line does the heavy lifting", "Sender, subject, and preview. No treasure hunt required.", True),
    ("Maple Desk", "Next week's office hours", "A short schedule for a busy week. Pick the time that works.", False),
)
DEFAULT_FG = "#e8ebf1"
DEFAULT_BG = "#111620"
MESSAGE_COUNT = 96
FIRST_MESSAGE_ID = "publication-mail-096"
INDEXED = ("#111620", "#ff7070", "#85cf95", "#ffc662", "#5cb1ff", "#bb9af7", "#5cb1ff", "#e8ebf1",
           "#8b95ab", "#ff7070", "#85cf95", "#ffc662", "#5cb1ff", "#bb9af7", "#5cb1ff", "#ffffff")


def fixture(directory):
    source = ProviderFixture(directory)
    for account in ACCOUNTS:
        baseline = source.data[account]["baseline"]
        template = baseline["messages"][0]
        messages = []
        baseline["labels"] = [{"id": "INBOX", "name": "Inbox", "type": "system"}]
        for index in range(MESSAGE_COUNT):
            sender, subject, snippet, unread = MAIL[index % len(MAIL)]
            if index >= len(MAIL):
                subject = f"Earlier notes {index + 1}: {subject}"
            message = copy.deepcopy(template)
            message_id = f"publication-mail-{MESSAGE_COUNT - index:03}"
            message.update(id=message_id, threadId=f"publication-thread-{MESSAGE_COUNT - index:03}",
                internalDate=str(1791280800000 - index * 1800000),
                labelIds=["INBOX", "UNREAD"] if unread else ["INBOX"], snippet=snippet)
            body = SMOKE_HTML if index == 0 else f"<html><body><p>Hello Morgan,</p><p>{html.escape(snippet)}</p><p>Cheers,<br>{html.escape(sender)}</p></body></html>"
            body_bytes = body.encode()
            message["sizeEstimate"] = len(body_bytes)
            message["payload"] = {
                "partId": "", "mimeType": "text/html", "filename": "",
                "headers": [
                    {"name": "From", "value": f"{sender} <personal@example.com>" if index == 0 else f"{sender} <hello@example.org>"},
                    {"name": "To", "value": "Morgan <work@example.com>" if index == 0 else account},
                    {"name": "Subject", "value": subject},
                    {"name": "Message-ID", "value": f"<{message_id}@example.org>"},
                    {"name": "Content-Type", "value": "text/html; charset=utf-8"},
                ],
                "body": {"size": len(body_bytes), "data": base64.urlsafe_b64encode(body_bytes).decode().rstrip("=")},
            }
            messages.append(message)
        baseline["messages"] = messages
        repage(baseline)
        source.stage(account, "baseline")
    return source


def seed(binary, directory, source, count=32, accounts=ACCOUNTS):
    with Client(binary, directory, extra=source.options()) as client:
        for account in accounts:
            client.request("mail.refresh", account, label="INBOX", limit=count, prefetchLimit=count)
            client.request("labels.list", account)
            message = client.request("mail.read", account, messageId=FIRST_MESSAGE_ID, cacheOnly=True)
            require(message["subject"] == SUBJECT and "Hello Morgan" in message["bodyText"], "publication fixture body was not cached")
            require("".join(SMOKE.split()) in "".join(message["bodyText"].split()), "publication smoke mail lost authored text")
        require(client.request("cache.stats")["fixtureSends"] == 0, "publication seeding sent mail")
    require(client.process.returncode == 0 and not client.stderr, "publication seed failed cleanup")


def terminal(binary, directory, source):
    return Terminal(binary, directory, extra=source.options(), screen_type=HtmlScreen,
        columns=160, rows=34, environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"})


def hero_snapshots(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source)
    tui = terminal(binary, directory, source)
    try:
        tui.until(lambda: reader_contains(tui.screen, "Your suspiciously productive volcano") and "Up to date" in tui.screen.lines()[1])
        tui.send(b"2")
        tui.until(lambda: "work@example.com" in tui.screen.lines()[0]
                  and reader_contains(tui.screen, "Hello Morgan,") and "Up to date" in tui.screen.lines()[1])
        tui.gap(.15)
        right = screen_capture(tui)
        tui.send(b":layout below\r")
        tui.until(lambda: "Reader below" in tui.screen.lines()[0] and reader_contains(tui.screen, "Your suspiciously productive volcano"))
        tui.gap(.15)
        below = screen_capture(tui)
        tui.finish()
        return right, below
    except Exception:
        print(tui.text())
        raise
    finally:
        tui.close()


def fetching_snapshots(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source, count=40, accounts=(ACCOUNTS[0],))
    hold, entered = source.root / "publication-fetch.hold", source.root / "publication-fetch.entered"
    tui = terminal(binary, directory, source)
    try:
        tui.until(lambda: reader_contains(tui.screen, "Hello Morgan,") and "Up to date" in tui.screen.lines()[1])
        for key, index in ((b"G", 31), (b"j", 32), (b"G", 39)):
            tui.send(key)
            expected = f"Earlier notes {index + 1}: {MAIL[index % len(MAIL)][1]}"
            tui.until(lambda text=expected: reader_contains(tui.screen, text))
        hold.write_text("Fictional publication checkpoint\n")
        path = source.path(ACCOUNTS[0])
        value = json.loads(path.read_text())
        value["sync"]["fixtureProgress"] = {"phase": "metadata", "completed": 1,
            "fixtureHold": hold.name, "fixtureEntered": entered.name}
        path.write_text(json.dumps(value, ensure_ascii=False))
        tui.send(b"j")
        tui.until(lambda: entered.exists() and "metadata 1/32" in tui.text())
        tui.until(lambda: "Earlier notes 41:" in tui.text())
        snapshots = []
        for _ in range(16):
            tui.gap(.16)
            snapshots.append(screen_capture(tui))
        require(len({tuple(frame["currentCells"]) for frame in snapshots}) >= 2, "actual loading output did not animate")
        require(all("metadata 1/32" in frame["currentCells"][1] for frame in snapshots), "capture invented a progress denominator")
        hold.unlink(missing_ok=True)
        tui.until(lambda: "Up to date" in tui.screen.lines()[1])
        tui.finish()
        return snapshots
    except Exception:
        print(tui.text())
        raise
    finally:
        hold.unlink(missing_ok=True)
        tui.close()


def color(value, fallback):
    if value is None:
        return fallback
    if value[0] == "rgb":
        return "#" + "".join(f"{part:02x}" for part in value[1:])
    index = value[1]
    if index < 16:
        return INDEXED[index]
    if index < 232:
        index -= 16
        cube = (0, 95, 135, 175, 215, 255)
        return "#" + "".join(f"{cube[part]:02x}" for part in (index // 36, index // 6 % 6, index % 6))
    shade = 8 + (index - 232) * 10
    return f"#{shade:02x}{shade:02x}{shade:02x}"


def render_data(snapshot, identity):
    grid = snapshot["cellGrid"]
    styles = [[None] * len(grid[0]) for _ in grid]
    for row, start, end, style in snapshot["currentStyleRuns"]:
        styles[row][start:end] = [style] * (end - start)
    glyphs = []
    for y, row in enumerate(grid):
        for x, text in enumerate(row):
            style = styles[y][x]
            fg, bg, bold, italic, underline, strike = (*style, False, False, False)[:6]
            background = color(bg, DEFAULT_BG)
            if not text and background == DEFAULT_BG:
                continue
            if text == " " and background == DEFAULT_BG:
                continue
            width = 2 if x + 1 < len(row) and row[x + 1] == "" else 1
            glyphs.append({"x": x, "y": y, "text": text, "columns": width,
                "fg": color(fg, DEFAULT_FG), "bg": background, "bold": bold,
                "italic": italic, "underline": underline, "strike": strike})
    return {"identity": identity, "columns": len(grid[0]), "rows": len(grid), "glyphs": glyphs}


QML = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property var frame: ({identity: "", columns: 160, rows: 34, glyphs: []})
  property real cellWidth: 9.6
  property int cellHeight: 24
  property int padding: 24
  FileView { id: input; onLoaded: root.frame = JSON.parse(text()) }
  FloatingWindow {
    implicitWidth: root.frame.columns * root.cellWidth + 2 * root.padding
    implicitHeight: root.frame.rows * root.cellHeight + 2 * root.padding
    visible: Quickshell.env("QT_QPA_PLATFORM") === "offscreen"
    color: "#111620"
    Rectangle {
      id: image
      anchors.fill: parent
      color: "#111620"
      Repeater {
        model: root.frame.glyphs
        delegate: Rectangle {
          required property var modelData
          x: root.padding + modelData.x * root.cellWidth
          y: root.padding + modelData.y * root.cellHeight
          width: modelData.columns * root.cellWidth
          height: root.cellHeight
          color: modelData.bg
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: parent.modelData.text
            textFormat: Text.PlainText
            color: parent.modelData.fg
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 16
            font.bold: parent.modelData.bold
            font.italic: parent.modelData.italic
            font.underline: parent.modelData.underline
            font.strikeout: parent.modelData.strike
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }
  IpcHandler {
    target: "omagma-terminal-capture"
    function load(path: string): void { input.path = path }
    function ready(): string { return root.frame.identity }
    function capture(path: string): void { image.grabToImage(function(result) { result.saveToFile(path) }) }
  }
}
'''


def isolated_environment(directory):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_SCALE_FACTOR="1")
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(name, None)
    env["HOME"] = str(directory / "home")
    for name in ("CONFIG", "CACHE", "DATA", "STATE"):
        env[f"XDG_{name}_HOME"] = str(directory / name.lower())
    runtime = directory / "runtime"
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    env["XDG_RUNTIME_DIR"] = str(runtime)
    return env


def render_snapshots(snapshots, directory, output):
    directory.mkdir(mode=0o700)
    config = directory / "shell.qml"
    config.write_text(QML)
    env = isolated_environment(directory)
    outputs = []
    with (directory / "render.log").open("w") as log:
        process = subprocess.Popen(["quickshell", "--path", str(config), "--no-color"], env=env, stdout=log, stderr=subprocess.STDOUT)
        def call(method, *params):
            return subprocess.check_output(["quickshell", "ipc", "--pid", str(process.pid), "call",
                "omagma-terminal-capture", method, *map(str, params)], env=env, text=True, stderr=subprocess.PIPE, timeout=5).strip()
        try:
            for index, snapshot in enumerate(snapshots):
                name = f"capture-{index:03}"
                data = directory / f"{name}.json"
                data.write_text(json.dumps(render_data(snapshot, name), ensure_ascii=False))
                deadline = time.monotonic() + 10
                loaded = False
                while time.monotonic() < deadline:
                    require(process.poll() is None, "offscreen terminal renderer exited")
                    try:
                        if not loaded:
                            call("load", data)
                            loaded = True
                        if call("ready") == name:
                            break
                    except subprocess.CalledProcessError:
                        pass
                    time.sleep(.05)
                else:
                    raise AssertionError("offscreen terminal frame did not load")
                time.sleep(.08)
                image = output(index)
                image.unlink(missing_ok=True)
                call("capture", image.resolve())
                deadline = time.monotonic() + 5
                while not complete_png(image) and time.monotonic() < deadline:
                    time.sleep(.03)
                require(complete_png(image), "offscreen terminal frame was not completely saved")
                strip_png_metadata(image)
                outputs.append(image)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    log_text = (directory / "render.log").read_text()
    require(not any(term in log_text for term in ("TypeError", "ReferenceError", "Binding loop", "Failed to load configuration")), "offscreen cell renderer produced a QML error")
    return outputs


def complete_png(path):
    if not path.is_file():
        return False
    data = path.read_bytes()
    return data.startswith(b"\x89PNG\r\n\x1a\n") and data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82")


def strip_png_metadata(path):
    data = path.read_bytes()
    require(complete_png(path), "renderer did not produce complete PNG")
    out, offset = bytearray(data[:8]), 8
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        chunk = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), "PNG chunk exceeds file")
        if chunk not in (b"tEXt", b"iTXt", b"zTXt", b"eXIf"):
            out.extend(data[offset:end])
        offset = end
    path.write_bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "docs/images")
    parser.add_argument("--skip-bar", action="store_true")
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="omagma-publication-") as temporary:
        directory = Path(temporary)
        right, below = hero_snapshots(binary, directory / "hero")
        frames = fetching_snapshots(binary, directory / "fetching")
        hero_names = (output / "omagma-tui.png", output / "omagma-tui-below.png")
        render_snapshots((right, below), directory / "render-hero", lambda index: hero_names[index])
        rendered = render_snapshots(frames, directory / "render-fetch", lambda index: directory / f"fetch-{index:03}.png")
        (output / "omagma-fetch.png").write_bytes(rendered[0].read_bytes())
        subprocess.run(["magick", "-delay", "16", *map(str, rendered), "-loop", "0", "-layers", "Optimize", "-strip", str(output / "omagma-fetch.gif")], check=True, timeout=60)
        if not args.skip_bar:
            env = isolated_environment(directory / "bar")
            subprocess.run(["python3", str(ROOT / "tests/ui_capture.py"), "--binary", str(binary), "--publication", "--selected", "--output", str(output / "omagma.png")], env=env, check=True, timeout=45)
            strip_png_metadata(output / "omagma.png")
        for image in (*hero_names, output / "omagma-fetch.png"):
            width, height = struct.unpack(">II", image.read_bytes()[16:24])
            print(f"PUBLIC SYNTHETIC {image.name}: {width}×{height}")
        print(f"PUBLIC SYNTHETIC omagma-fetch.gif: {len(frames)} actual frames; {len((output / 'omagma-fetch.gif').read_bytes())} bytes")


if __name__ == "__main__":
    main()
