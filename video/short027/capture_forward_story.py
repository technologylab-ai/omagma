#!/usr/bin/env python3
"""Record the complete synthetic received-mail-to-forward story, without sending."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "video/short027"))
from capture import reservation, recorder, ready, save_tape, no_send
from capture_fixture import make, options, seed, WORK, BOOKING_ID, BOOKING_SUBJECT, BOOKING_HTML, NOTE
from terminal_integration import Client, require
from terminal_pty import wait_saved_compose
from build_info import read_build_info


def mark(rec, name, **info):
    rec.gap(.12)
    rec.mark(name, **info)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "video/cache/short027")
    args = parser.parse_args()
    reservation()
    binary = args.binary.resolve()
    binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(binary_sha == args.expected_sha256, "capture executable changed")
    info = read_build_info(binary)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "assets").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="omagma-forward-story-") as temporary:
        directory = Path(temporary)
        source, config, _ = make(directory)
        extra = options(source, config)
        seed(binary, directory, source, config)
        rec = recorder(binary, directory, source, config, "forward-story")
        try:
            ready(rec)
            rec.press("j", "received:select", show=False)
            rec.wait(lambda: BOOKING_SUBJECT in rec.text() and "Lisbon is calling." in rec.text()
                     and rec.line(rec.rows - 1).strip() == "Ready")
            mark(rec, "received", messageId=BOOKING_ID)
            rec.press("f", "forward:open")
            rec.wait(lambda: "[Keep formatting k]" in rec.text() and "[Text quote t]" in rec.text())
            mark(rec, "forward-menu")
            rec.press("k", "forward:keep-formatting")
            wait_saved_compose(rec, attachment_count=0)
            with Client(binary, directory, extra=extra) as client:
                drafts = client.request("draft.list", WORK)["drafts"]
                require(len(drafts) == 1, "expected one new forward draft")
                draft_id = drafts[0]["id"]
                empty = client.request("draft.read", WORK, draftId=draft_id)
                require(empty.get("original") is not None, "original HTML was not retained")
                require("Hi Maya," not in empty["bodyText"], "new note was already authored")
                require(empty["original"]["bodyHtml"] == BOOKING_HTML, "received HTML changed")
            mark(rec, "empty-composer", editableNoteEmpty=True, generatedSignatureRetained=True)
            rec.press("imaya@example.org\t\t\t\t", "forward:recipient", show=False)
            rec.wait(lambda: "Body: INSERT" in rec.text())
            rec.press(b"\x07", "note:top", show=False)
            mark(rec, "empty-note", editableNoteEmpty=True)
            typed_marks = []
            chunk = 18
            for index, char in enumerate(NOTE, 1):
                rec.send(b"\r" if char == "\n" else char.encode())
                rec.gap(.012)
                if index % chunk == 0 or index == len(NOTE):
                    name = f"typed-{len(typed_marks) + 1:02d}"
                    mark(rec, name, typedCharacters=index, totalCharacters=len(NOTE))
                    typed_marks.append(name)
            rec.press(b"\x07", "note:top-after-typing", show=False)
            rec.press(b"\x1b", "note:normal", show=False)
            wait_saved_compose(rec, attachment_count=0)
            rec.wait(lambda: "Hi Maya," in rec.text() and "Lisbon trip" in rec.text()
                     and "Outgoing preview" in rec.text())
            mark(rec, "final-note")
            # Autosave preserves the editable recovery snapshot; the normal
            # review action commits the primary draft used by browser preview.
            # Opening review never submits the mail.
            rec.press(b"\x13", "forward:save-for-browser", show=False)
            rec.wait(lambda: "Review send" in rec.text() and "[Back]" in rec.text())
            with Client(binary, directory, extra=extra) as client:
                draft = client.request("draft.read", WORK, draftId=draft_id)
                if not draft["bodyText"].startswith(NOTE):
                    (out / "forward-story-typing-mismatch.json").write_text(json.dumps({
                        "expectedNote": NOTE, "actualBody": draft["bodyText"],
                    }, ensure_ascii=False, indent=2) + "\n")
                require(draft["bodyText"].startswith(NOTE), "typed note changed or lost characters")
                require(draft["bodyFormat"] == "markdown", "note is not Markdown")
                require(draft["original"]["bodyHtml"] == BOOKING_HTML, "original changed while typing")
                preview = client.request("draft.preview", WORK, draftId=draft_id)
                require("EMBER AIR" in preview["bodyHtml"] and "<table" in preview["bodyHtml"]
                        and "cid:ember-" in preview["bodyHtml"]
                        and len(draft["original"]["resources"]) == 2, "preview lost original layout/images")
                opened = client.request("draft.open-preview", WORK, draftId=draft_id)
                require(opened["fixture"] and not opened["opened"], "desktop browser was launched")
                shutil.copyfile(opened["path"], out / "assets/forward-story-browser.html")
                (out / "forward-story-proof.json").write_text(json.dumps({
                    "binarySha256": binary_sha, "buildInfo": info,
                    "sourceId": BOOKING_ID, "originalHtmlSha256": hashlib.sha256(BOOKING_HTML.encode()).hexdigest(),
                    "bodyText": draft["bodyText"], "bodyFormat": draft["bodyFormat"],
                    "emptyInitialBodyText": empty["bodyText"], "typedCharacters": len(NOTE),
                    "typingMarks": typed_marks, "immutableOriginal": True, "browserDryOpen": True,
                    "embeddedImages": len(draft["original"]["resources"]),
                }, ensure_ascii=False, indent=2) + "\n")
            no_send(binary, directory, extra)
            finished = rec.finish(client_extra=extra)
            save_tape(rec, out, info)
            receipt = {"binarySha256": binary_sha, "buildInfo": info, "synthetic": True,
                       "liveProviderWrites": 0, "fixtureSends": 0, "typingFrames": len(typed_marks),
                       "allChildrenReaped": True, "cleanup": finished}
            (out / "forward-story-capture-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt))
        except Exception:
            save_tape(rec, out, info)
            raise
        finally:
            rec.close()


if __name__ == "__main__":
    main()
