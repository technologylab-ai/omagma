#!/usr/bin/env python3
"""Record the film's real TUI takes and the CLI cameo with fictional fixtures.

    python3 video/capture/takes.py --binary zig-out/bin/omagma --out video/cache/capture

Each take drives the published executable (`omagma tui --fixtures`) through an
owned PTY: no desktop window, no user terminal, no real account. Fixture sends
are counted and must equal the one explicit `y` in the compose take. Run only
inside a coordinated host reservation (see video/README.md).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))

from promo_fixture import (ATTACHMENTS, CC_ADDRESS, CC_QUERY, OPTIONAL, OPTIONAL_MAIL, PERSONAL,  # noqa: E402
                           PERSONAL_MAIL, REPLY_BODY, ROOT, SUBJECT, WORK, WORK_MAIL, attachment_files, fixture,
                           known_addresses, seed)
from tape import Recorder, privacy_scan, save  # noqa: E402
from terminal_integration import require  # noqa: E402
from terminal_reader import reader_contains  # noqa: E402

MARKER = ".omagma-promo-capture"


def subject(index):
    sender, address, text, snippet, unread = WORK_MAIL[index % len(WORK_MAIL)]
    return text if index < len(WORK_MAIL) else f"Earlier notes {index + 1}: {text}"


def probe(index):
    """A short unique prefix; the reader wraps long subjects across rows."""
    return subject(index)[:24] if index < len(WORK_MAIL) else f"Earlier notes {index + 1}: "


def settled(rec):
    rec.wait(lambda: "Up to date" in rec.line(1) and reader_contains(rec.screen, "Hello Morgan,"), name="settled")


def main_take(binary, directory, size):
    """Startup over a cached inbox, accounts, Vim keys, a click, layouts, HTML, cache search."""
    source = fixture(directory)
    seed(binary, directory, source)
    source.stage(WORK, "baseline", held=True)
    rec = Recorder(binary, directory, "main", extra=source.options("--account", WORK), columns=size[0], rows=size[1])
    try:
        rec.mark("launch")
        rec.wait(lambda: SUBJECT in rec.text(), name="cached")
        rec.wait(lambda: source.is_held(WORK), name="refreshing")
        rec.gap(1.2)
        source.release(WORK)
        rec.mark("released")
        settled(rec)
        rec.wait(lambda: reader_contains(rec.screen, "Your suspiciously productive volcano"), name="current")
        rec.gap(.8)

        for key, account, expected in (("1", PERSONAL, PERSONAL_MAIL[0][2]), ("3", OPTIONAL, OPTIONAL_MAIL[0][2]), ("2", WORK, SUBJECT)):
            rec.press(key, f"account:{key}")
            rec.wait(lambda: account in rec.line(0) and expected in rec.text(), name=f"account:{key}:shown")
            rec.wait(lambda: "Up to date" in rec.line(1))
            rec.gap(.5)

        for index in (1, 2, 3):
            rec.press("j", f"nav:j{index}")
            rec.wait(lambda: reader_contains(rec.screen, probe(index)), name=f"nav:j{index}:shown")
            rec.gap(.25)
        rec.wait(lambda: rec.screen.mouse & {1000, 1002, 1003}, name="mouse-ready")
        column, row = rec.locate("Omagma smoke test")
        rec.click(column + 4, row, "click:smoke")
        rec.wait(lambda: reader_contains(rec.screen, "Your suspiciously productive volcano"), name="read:smoke")
        rec.gap(1.5)

        rec.press("v", "layout:below")
        rec.wait(lambda: "Reader below" in rec.line(0), name="layout:below:shown")
        rec.gap(.8)
        rec.press("z", "layout:expand")
        rec.wait(lambda: "Mail ·" not in rec.text(), name="layout:expand:shown")
        rec.gap(.8)
        rec.press("z", "layout:restore")
        rec.wait(lambda: "Mail ·" in rec.text())
        rec.press("v", "layout:right")
        rec.wait(lambda: "Reader right" in rec.line(0), name="layout:right:shown")
        rec.gap(.5)

        # The click and layout keys leave the reader focused; J moves to the adjacent mail from there.
        rec.press("J", "html:select")
        rec.wait(lambda: reader_contains(rec.screen, "October build notes"), name="html:shown")
        rec.gap(.8)
        rec.press("z", "html:expand")
        rec.wait(lambda: "Mail ·" not in rec.text() and reader_contains(rec.screen, "Exports"), name="html:table")
        rec.gap(1.5)
        rec.press("z", "html:restore")
        rec.wait(lambda: "Mail ·" in rec.text())
        rec.gap(.4)

        rec.press("/", "search:open")
        rec.wait(lambda: "Cache / " in rec.text(), name="search:prompt")
        rec.type("volcano", "search:type", delay=.06)
        rec.press("\r", "search:enter")
        # The title reads "Cache search" while typing; the filtered results view is "Inbox / Cache search".
        rec.wait(lambda: "Inbox / Cache search" in rec.line(0) and "Searching cached mail" not in rec.line(1)
                 and "Friday's launch checklist" not in rec.text(), name="search:results")
        rec.gap(1.5)
        rec.press("q", "search:back")
        rec.wait(lambda: "Cache search" not in rec.line(0), name="search:restored")
        rec.gap(.6)
        rec.mark("end")
        return rec, rec.finish(client_extra=source.options())
    finally:
        rec.close()


def stream_take(binary, directory, size):
    """j past the cached tail: real placeholders and the real `metadata 1/32` batch line."""
    source = fixture(directory)
    seed(binary, directory, source, count=40, accounts=(WORK,))
    hold, entered = source.root / "promo-fetch.hold", source.root / "promo-fetch.entered"
    rec = Recorder(binary, directory, "stream", extra=source.options("--account", WORK), columns=size[0], rows=size[1])
    try:
        settled(rec)
        rec.gap(.5)
        rec.mark("scroll")
        for index in range(1, 40):
            rec.press("j", f"stream:j{index}", show=index <= 3)
            rec.wait(lambda: reader_contains(rec.screen, probe(index)))
            rec.gap(.06)
        rec.mark("tail")
        hold.write_text("Fictional promo checkpoint\n")
        path = source.path(WORK)
        value = json.loads(path.read_text())
        value["sync"]["fixtureProgress"] = {"phase": "metadata", "completed": 1,
                                            "fixtureHold": hold.name, "fixtureEntered": entered.name}
        path.write_text(json.dumps(value, ensure_ascii=False))
        rec.press("j", "stream:fetch")
        rec.wait(lambda: entered.exists() and "metadata 1/32" in rec.text(), name="stream:held")
        rec.wait(lambda: "Earlier notes 41:" in rec.text(), name="stream:row")
        rec.gap(3.0)
        require("metadata 1/32" in rec.text(), "the held fetch stopped before release")
        # Release the fictional provider: the real older rows replace the placeholders.
        hold.unlink()
        rec.mark("stream:released")
        rec.wait(lambda: "Fetching metadata" not in rec.text() and "Earlier notes 42:" in rec.text(), seconds=15, name="stream:arrived")
        rec.wait(lambda: "Up to date" in rec.line(1), seconds=15, name="stream:current")
        rec.gap(.8)
        for index in (2, 3, 4):
            rec.press("k", f"stream:k{index}")
            rec.gap(.35)
        rec.gap(.6)
        rec.mark("end")
        return rec, rec.finish(client_extra=source.options())
    finally:
        hold.unlink(missing_ok=True)
        rec.close()


def compose_take(binary, directory, size, files):
    """Reply-all with local Cc completion, two attachments, review, then exactly one fixture send."""
    paths = attachment_files(files)
    source = fixture(directory)
    seed(binary, directory, source, accounts=(WORK,))
    rec = Recorder(binary, directory, "compose", extra=source.options("--account", WORK), columns=size[0], rows=size[1])
    try:
        settled(rec)
        rec.gap(.6)
        rec.press("R", "reply:all")
        rec.wait(lambda: "Subject:" in rec.text() and "Re: Omagma smoke test" in rec.text(), name="reply:open")
        rec.gap(.8)
        rec.press("\t", "reply:cc")
        rec.press("i", "reply:insert-cc")
        rec.type(CC_QUERY, "reply:cc-type", delay=.12)
        rec.wait(lambda: CC_ADDRESS in rec.text(), name="reply:suggestion")
        rec.gap(.6)
        rec.press("\x0e", "reply:ctrl-n")
        rec.gap(.4)
        rec.press("\r", "reply:accept")
        rec.wait(lambda: any("Cc:" in line and CC_ADDRESS in line for line in rec.screen.lines()), name="reply:cc-set")
        rec.press("\x1b", "reply:normal")
        rec.gap(.3)
        rec.press("\t\t\t", "reply:body", show=False)
        rec.press("i", "reply:insert-body")
        rec.type(REPLY_BODY, "reply:type", delay=.03)
        rec.press("\x1b", "reply:typed")
        rec.wait(lambda: "Draft saved locally" in rec.text(), seconds=10, name="draft:saved")
        rec.gap(.6)
        for count, (path, (name, prefix)) in enumerate(zip(paths, ATTACHMENTS), 1):
            rec.press("A", f"attach:{count}")
            rec.wait(lambda: "Attach file path:" in rec.text(), name=f"attach:{count}:prompt")
            rec.type(str(path.parent / prefix), f"attach:{count}:path", delay=.02)
            rec.press("\t", f"attach:{count}:tab")
            rec.wait(lambda: name in rec.text(), name=f"attach:{count}:completed")
            rec.gap(.4)
            rec.press("\r", f"attach:{count}:enter")
            rec.wait(lambda: f"Attachments {count}" in rec.text(), name=f"attach:{count}:listed")
            rec.gap(.6)
        rec.press("\x13", "review:open")
        rec.wait(lambda: "Sending account:" in rec.text(), name="review:shown")
        rec.gap(1.5)
        rec.press("y", "send:y")
        rec.wait(lambda: "Saved by mock provider" in rec.text(), name="send:done")
        rec.gap(2.5)
        rec.mark("end")
        return rec, rec.finish(expected_sends=1, client_extra=source.options())
    finally:
        rec.close()


def cli_take(binary, directory):
    """The exact one-shot command a reader can run against the built-in fixtures,
    pretty-printed by a real `jq .` so the cameo is legible; both outputs are kept."""
    command = ["omagma", "mail", "list", "--fixtures", "--account", WORK, "--limit", "2"]
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "TZ": "UTC0", "HOME": str(directory / "home")}
    for name in ("CONFIG", "CACHE", "DATA", "STATE"):
        env[f"XDG_{name}_HOME"] = str(directory / name.lower())
    (directory / "home").mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(binary), *command[1:]], capture_output=True, text=True, env=env, cwd=directory, timeout=30)
    require(result.returncode == 0 and not result.stderr.strip(), "fixture CLI cameo failed")
    pretty = subprocess.run(["jq", "."], input=result.stdout, capture_output=True, text=True, timeout=30, check=True).stdout
    privacy_scan([result.stdout, pretty], known=known_addresses())
    return {"command": " ".join(command) + " | jq .", "stdout": pretty, "raw": result.stdout}


def binary_info(binary):
    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=5).stdout.strip()
    try:
        build = json.loads(subprocess.run([str(binary), "build-info"], capture_output=True, text=True, timeout=5).stdout)
    except (json.JSONDecodeError, subprocess.SubprocessError):
        build = {}
    return {"version": version, "sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(), **build}


def owned_root(path):
    """Use a fixed, generic, owned scratch path so typed paths look the same in every capture."""
    if path.exists():
        require((path / MARKER).is_file() and path.stat().st_uid == os.getuid(),
                f"{path} exists and is not a previous promo capture root; choose another --scratch")
        shutil.rmtree(path)
    path.mkdir(mode=0o700, parents=True)
    (path / MARKER).write_text("omagma promo capture scratch\n")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--out", type=Path, default=ROOT / "video/cache/capture")
    parser.add_argument("--scratch", type=Path, default=Path("/tmp/omagma-demo"),
                        help="owned scratch root; its files path is visible in the attach prompt")
    parser.add_argument("--takes", default="main,stream,compose,cli")
    parser.add_argument("--size", default="132x36", help="terminal columns x rows")
    args = parser.parse_args()
    binary = args.binary.resolve()
    size = tuple(int(v) for v in args.size.lower().split("x"))
    takes = [take.strip() for take in args.takes.split(",") if take.strip()]
    out = args.out.resolve()
    (out / "tapes").mkdir(parents=True, exist_ok=True)
    info = binary_info(binary)
    receipt_path = out / "capture.json"
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    receipt.update(binary=info, size=list(size), captured=time.strftime("%Y-%m-%d", time.gmtime()),
                   fixtures="video/capture/promo_fixture.py (fictional)")
    receipt.setdefault("takes", {})
    root = owned_root(args.scratch)
    try:
        for take in takes:
            directory = root / take
            started = time.monotonic()
            if take == "cli":
                directory.mkdir(mode=0o700)
                value = cli_take(binary, directory)
                (out / "cli.json").write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
                receipt["takes"][take] = {"lines": len(value["stdout"].splitlines())}
                print(f"cli: {len(value['stdout'].splitlines())} lines")
                continue
            if take == "main":
                rec, finished = main_take(binary, directory, size)
            elif take == "stream":
                rec, finished = stream_take(binary, directory, size)
            elif take == "compose":
                rec, finished = compose_take(binary, directory, size, root / "files")
            else:
                raise SystemExit(f"unknown take {take!r}")
            save(out / "tapes" / f"{take}.json", rec.tape(info), known=known_addresses())
            if os.environ.get("PROMO_RAW"):
                (out / f"{take}.raw").write_bytes(bytes(rec.output))
            receipt["takes"][take] = {"frames": len(rec.frames), "marks": len(rec.marks),
                                      "seconds": round(time.monotonic() - started, 1),
                                      "fixtureSends": finished["observedFixtureSends"], "termiosRestored": finished["termiosRestored"]}
    finally:
        if (root / MARKER).is_file():
            shutil.rmtree(root)
    receipt_path.write_text(json.dumps(receipt, indent=1) + "\n")


if __name__ == "__main__":
    main()
