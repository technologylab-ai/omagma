#!/usr/bin/env python3
"""Genuine v0.2.6 promo UI in owned PTYs and isolated fictional fixture homes.
Media/dev tooling only. No account credentials, desktop input or live sends.
Run only under a coordinator-delegated HOST_TOKEN reservation.
"""
from __future__ import annotations
import argparse, base64, copy, hashlib, json, os, re, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "video/capture"), str(ROOT / "tests"), str(ROOT / "video/tools")]
from tape import Recorder, save
from promo_fixture import fixture, seed, ACCOUNTS, WORK, SUBJECT
from terminal_arrivals_publication import arrival_wave
from terminal_arrivals import refresh
from terminal_integration import Client, require
from build_info import read_build_info
from host_lock import owner, identity, start_ticks
from picker_fixture import create as create_picker_files, record as record_picker, attach_selected
BODY = """# Small eruptions, big ideas 🌋

- Quiet new-mail cards
- Files, picked locally
- Markdown, beautifully sent

| Feature | Status |
| --- | --- |
| Inbox | Calm |
| Composer | Ready |

```python
def hello():
    print("Hello, volcano!")
```

```zig
fn hello() void {
    std.debug.print("Hello, volcano!\\n", .{});
}
```

[Read the notes](https://example.test/notes) · `something`
"""
def reservation():
    value = owner()
    who = identity(value) if value else None
    require(value and value.get("token") == os.environ.get("HOST_TOKEN") and who and start_ticks(who[0]) == who[1],
            "requires live coordinator reservation and matching HOST_TOKEN")
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "video/cache/short026")
    args = parser.parse_args()
    reservation()
    binary = args.binary.resolve()
    sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(sha == args.expected_sha256, "capture binary changed")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    info = read_build_info(binary)
    (out / "body.md").write_text(BODY)
    with tempfile.TemporaryDirectory(prefix="omagma-short026-") as temporary:
        directory = Path(temporary)
        source = fixture(directory)
        # The existing authored fictional fixture uses reserved example.com,
        # .org and .net addresses. New composed peers use example.test.
        seed(binary, directory, source)
        picker_files = create_picker_files(directory, ROOT)
        (directory / "home").mkdir(exist_ok=True)
        notification = Recorder(binary, directory, "notification", extra=source.options("--account", WORK), columns=132, rows=36)
        try:
            notification.wait(lambda: "Up to date" in notification.text() and SUBJECT in notification.text(), name="inbox")
            notification.gap(1.2)
            require("New mail" not in notification.text(), "startup replayed cached arrivals")
            arrival_wave(source, WORK, 2, 1001)
            refresh(binary, directory, source, notification)
            notification.wait(lambda: "New mail" in notification.text() and "2 new messages" in notification.text(), name="arrived")
            notification.gap(.25)
            notification.mark("hero")
            result_notice = notification.finish(client_extra=source.options())
            save(out / "notification.json", notification.tape(info), known=("work@example.com", "personal@example.com", "optional@example.com", "hello@example.test"))
        finally:
            notification.close()
        rec = Recorder(binary, directory, "compose", extra=source.options("--account", WORK), columns=160, rows=42)
        try:
            rec.wait(lambda: "Up to date" in rec.text() and "| Compose |" not in rec.line(0), name="ready")
            rec.press("c", "compose:open")
            rec.wait(lambda: "Subject:" in rec.text() and "Body:" in rec.text())
            rec.press("imaya@example.test\t\t\tSmall eruptions, big ideas\t", "compose:headers", show=False)
            rec.press(b"\x1b[200~" + BODY.encode() + b"\x1b[201~", "compose:paste", show=False)
            rec.wait(lambda: "something" in rec.text() and "hello()" in rec.text(), name="body:ready")
            rec.press(b"\x1b", "compose:normal", show=False)
            rec.gap(.15)
            rec.mark("composer")
            picker_audit = record_picker(rec)
            attach_selected(rec)
            rec.press(b"\x13", "review")
            rec.wait(lambda: "Review send" in rec.text() and "Sending account:" in rec.text(), name="review:shown")
            with Client(binary, directory, extra=source.options()) as client:
                drafts = client.request("draft.list", WORK)["drafts"]
                require(len(drafts) == 1, "capture changed draft count")
                draft = client.request("draft.read", WORK, draftId=drafts[0]["id"])
                require(draft["bodyFormat"] == "markdown" and draft["bodyText"] == BODY, "capture changed exact Markdown source")
                preview = client.request("draft.preview", WORK, draftId=draft["id"])
                require("<table" in preview["bodyHtml"] and "hello" in preview["bodyHtml"] and "omagma" in preview["bodyHtml"], "actual preview omitted demo")
                require(client.request("cache.stats", WORK)["fixtureSends"] == 0, "promo sent mail")
                (out / "preview.json").write_text(json.dumps(preview, ensure_ascii=False, indent=2))
                html = preview["bodyHtml"]
                cid = re.findall(r'src="(cid:[^"]+)"', html)
                require(len(cid) == 1, "actual footer has no unique logo CID")
                png = (ROOT / "assets/omagma-logo.png").read_bytes()
                html = html.replace(cid[0], "data:image/png;base64," + base64.b64encode(png).decode())
                assets = out / "assets"
                assets.mkdir(exist_ok=True)
                (assets / "browser.html").write_text(html)
                (out / "cid-resolution.json").write_text(json.dumps({"previewLogoUri":cid[0], "sha256":hashlib.sha256(png).hexdigest(), "bytes":len(png), "source":"assets/omagma-logo.png", "modification":"browser copy only: one actual CID img URI resolved to exact trusted PNG bytes; renderer CSS/content unchanged"}))
            rec.press(b"\x1b", "review:back", show=False)
            rec.wait(lambda: "Review send" not in rec.text() and "Outgoing preview" in rec.text())
            rec.mark("composer-final")
            result_compose = rec.finish(client_extra=source.options())
            save(out / "compose.json", rec.tape(info), known=("work@example.com", "personal@example.com", "optional@example.com", "maya@example.test"))
        finally:
            rec.close()
    (out / "capture-receipt.json").write_text(json.dumps({"binarySha256":sha, "buildInfo":info, "synthetic":True, "liveProviderWrites":0, "fixtureSends":0, "notification":result_notice, "compose":result_compose, "body":BODY,"pickerFiles":picker_files,"pickerAudit":picker_audit}, ensure_ascii=False, indent=2))
    print("captured genuine notification, attachment picker, Markdown source/preview and actual CLI HTML; no sends")
if __name__ == "__main__": main()
