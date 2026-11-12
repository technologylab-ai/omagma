#!/usr/bin/env python3
"""Two genuine result-clarity takes; released binary and fictional providers."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture as base


def bounds(rec, literal):
    point = rec.screen.locate(literal)
    base.require(point is not None, "visible anchor absent: " + literal)
    return [point["column"], point["row"], len(literal), 1]


def union(*rects):
    x, y = min(r[0] for r in rects), min(r[1] for r in rects)
    return [x, y, max(r[0] + r[2] for r in rects) - x, max(r[1] + r[3] for r in rects) - y]


def marked(rec, out, manifest, key, camera_name, camera, spots):
    base.mark(rec, manifest, out, key, rois={camera_name: camera, **spots})
    normalized = [camera[0] / rec.columns, camera[1] / rec.rows, camera[2] / rec.columns, camera[3] / rec.rows]
    manifest["assets"][key]["cameraRois"] = {camera_name: normalized}
    manifest["assets"][key]["cellCameras"] = {camera_name: camera}
    manifest["assets"][key]["bindingCells"] = {camera_name: camera, **spots}


def clear(binary, directory, out, manifest, baseline):
    story = base.CalendarStory(directory)
    now = datetime.now(timezone.utc)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    hour = now.replace(minute=0, second=0, microsecond=0)
    base.require(now.hour < 23, "live UTC day has no later hour for a clear-line story")
    haircut = baseline["proofs"]["booking"]["identity"]
    base.require(haircut["day"] == (today + timedelta(days=1)).date().isoformat(), "baseline Haircut is no longer tomorrow")
    story.monday = today - timedelta(days=today.weekday())
    story.seed(binary)
    events = [
        (base.WORK, "fixture-shared-team", hour - timedelta(hours=2), 45, "Focus"),
        (base.WORK, base.WORK, hour + timedelta(hours=min(2, 23 - now.hour)), 45, "Call"),
        (base.ACCOUNTS[2], base.ACCOUNTS[2], today + timedelta(days=1, hours=15), 45, "Review"),
        (base.WORK, base.WORK, today + timedelta(days=2, hours=9), 60, "Plan"),
    ]
    for path in (directory / "cache").rglob("calendar-provider-fixture.json"):
        state = json.loads(path.read_text())
        state["events"] = []
        for index, (account, calendar, first, duration, title) in enumerate(events):
            if state["account"] != account:
                continue
            state["events"].append({"calendar_id": calendar, "value": {
                "id": "clear-" + str(index), "iCalUID": "clear-" + str(index) + "@example.org",
                "etag": '"story-1"', "status": "confirmed", "summary": title,
                "organizer": {"email": base.MAYA},
                "start": {"dateTime": first.isoformat().replace("+00:00", "Z")},
                "end": {"dateTime": (first + timedelta(minutes=duration)).isoformat().replace("+00:00", "Z")}}})
        if state["account"] == base.ACCOUNTS[0]:
            state["events"].append({"calendar_id": base.ACCOUNTS[0], "value": {
                "id": "studio-haircut", "iCalUID": haircut["uid"], "etag": '"story-1"',
                "status": "confirmed", "summary": "Haircut", "organizer": {"email": "bookings@example.org"},
                "start": {"dateTime": haircut["start"]}, "end": {"dateTime": haircut["end"]}}})
        base.write_json(path, state)
    rec = base.start(binary, directory, story, "nowclear", columns=120, rows=32)
    try:
        rec.press("C", "clear.calendar")
        rec.wait(lambda: "Calendar · Agenda" in rec.text())
        rec.press("t3", "clear.week")
        rec.wait(lambda: "Calendar · Week" in rec.text() and rec.screen.locate("now") is not None)
        rec.press("k" * 6, "clear.select-focus", show=False)
        rec.wait(lambda: "Focus" in rec.screen.lines()[-4])
        row = bounds(rec, "now")[1]
        columns = [x for x, style in enumerate(rec.screen.styles[row]) if style[4] and style[6] is not None]
        base.require(columns and all(not rec.screen.cells[row][x].strip() for x in columns), "now line crosses event glyphs")
        focus, call, booked = bounds(rec, "Focus"), bounds(rec, "Call"), bounds(rec, "Haircut")
        base.require(focus[1] <= row - 1 and call[1] >= row + 1, "earlier/later event do not bracket now")
        header = next(y for y, text in enumerate(rec.screen.lines()) if any(day in text for day in
                      ("Mon ", "Tue ", "Wed ", "Thu ", "Fri ", "Sat ", "Sun ")))
        base.require(row + 2 < rec.rows and booked[0] < 70, "authored week context is outside viewport")
        camera = [0, header, 70, row + 3 - header]
        apparent = 36.6666666667 * min(1652 / (70 * 22), 732 / (camera[3] * 44), 1)
        base.require(apparent >= 26, "clear calendar camera text would be too small")
        marked(rec, out, manifest, "calendar.clear", "hero", camera, {"nowRow": [0, row, max(columns) + 1, 1]})
        manifest["proofs"]["calendar.clear"] = {
            "captureUtc": datetime.now(timezone.utc).isoformat(), "row": row,
            "underlinedColumns": columns, "underlineColors": [rec.screen.styles[row][x][6] for x in columns],
            "underlinedGlyphs": [rec.screen.cells[row][x] for x in columns],
            "gutterColor": rec.screen.styles[row][0][0], "bookingIdentity": haircut,
            "earlierEventCell": focus, "laterEventCell": call, "cameraCells": camera,
            "apparentFontPx": apparent, "clock": "Actual OS real time", "fixtureSends": 0}
        manifest["cleanup"]["calendar.clear"] = rec.finish(client_extra=story.options())
    finally:
        base.preserve(rec, manifest["buildInfo"], out)


def sent(binary, directory, out, manifest, baseline):
    story = base.fixture_story(binary, directory)
    preferences = json.loads(story.preferences.read_text())
    preferences["contexts"] = [{"account": base.WORK, "folder": 1, "selected": 0, "readerScroll": 0}]
    base.write_json(story.preferences, preferences)
    rec = base.CaptureRecorder(binary, directory, "sent-result", columns=100, rows=24,
        extra=(*story.options(), "--account", base.WORK, "--ui-file", str(story.preferences),
               "--fixture-scenario", "drive-enabled"))
    try:
        rec.wait(lambda: "Sent" in rec.screen.lines()[0] and ("Up to date" in rec.text() or "Ready" in rec.text()))
        rec.press("c", "sent.compose")
        rec.wait(lambda: "Subject:" in rec.text())
        rec.press("i" + base.MAYA + "\t" + base.LEO + "\t\tThis week at Ember Studio\tA little planning, focused work, and a good conversation.\x1b",
                  "sent.headers", show=False)
        base.persisted(rec, binary, directory, story.options(), lambda d: "conversation." in base.source_body(d))
        artifact = directory / "launch-film-master.mov"
        with artifact.open("wb") as stream: stream.truncate(26 * 1024 * 1024)
        rec.press("A", "sent.attach")
        rec.wait(lambda: "Attach file · local draft" in rec.text())
        rec.press(str(artifact) + "\r", "sent.file", show=False)
        rec.wait(lambda: "Too large to attach" in rec.text())
        rec.press("d", "sent.drive")
        rec.wait(lambda: "[Drv     ]" in rec.text())
        base.persisted(rec, binary, directory, story.options(),
            lambda draft: len(draft["attachments"]) == 1 and draft["attachments"][0]["delivery"] == "drive")
        rec.press(b"\x13", "sent.review")
        rec.wait(lambda: "Review send" in rec.text() and "[y Send]" in rec.text())
        rec.press("y", "sent.confirm")
        rec.wait(lambda: "Sending in " in rec.text())
        rec.press(b"\x13", "sent.send-now")
        rec.wait(lambda: "Send complete · provider accepted" in rec.text(), seconds=20)
        # Populate the cached Sent view through the normal provider list API;
        # the compact TUI's cache-only refresh does not fetch an unvisited view.
        with base.Client(binary, directory, scenario="drive-enabled", extra=story.options()) as client:
            sent_rows = client.request("mail.list", base.WORK, label="SENT", limit=30)["messages"]
            base.require(any(message["subject"] == "This week at Ember Studio" for message in sent_rows),
                         "genuinely delivered message absent from provider Sent list")
        rec.press(b"\x12", "sent.refresh-folder")
        rec.wait(lambda: "Sent" in rec.screen.lines()[0] and "This week at Ember Studio" in rec.text())
        # Open the genuinely selected delivered message, using the ordinary
        # reader action if its compact split has not exposed the Drive line.
        if "launch-film-master.mov" not in rec.text():
            rec.press(b"\r", "sent.read-delivered")
            rec.wait(lambda: "To:" in rec.text() and base.MAYA in rec.text() and base.LEO in rec.text())
        to, cc = bounds(rec, "To:"), bounds(rec, "Cc:")
        link = rec.screen.locate("launch-film-master.mov")
        link_kind = "Drive filename" if link else "Actual To/Cc rows; no Drive line visible in this viewport"
        target = bounds(rec, "launch-film-master.mov") if link else union(to, cc)
        # SENT label is a real reader marker even when the expanded reader
        # replaces the split list. Keep its header through the genuine link.
        marker = rec.screen.locate("Labels: SENT") or rec.screen.locate("Sent")
        base.require(marker is not None, "actual Sent marker missing")
        top = min(marker["row"], to[1], cc[1])
        bottom = max(target[1] + target[3], to[1] + 1, cc[1] + 1)
        x = min(to[0], cc[0], target[0], 10)
        camera = [x, max(0, min(top - 1, rec.rows - 20)), 90, 20]
        base.require(bottom <= camera[1] + camera[3], "actual Sent header/link span exceeds twenty rows")
        marked(rec, out, manifest, "drive.sent", "result", camera, {"link": target})
        with base.Client(binary, directory, scenario="drive-enabled", extra=story.options()) as client:
            history = client.request("history.operations", base.WORK)["items"]
            base.require(len(history) == 1 and history[0]["outcome"] == "applied", "Sent take did not submit exactly once")
            receipt = client.request("operation.read", base.WORK, operationId=history[0]["id"])
            delivered = client.request("mail.read", base.WORK, messageId=receipt["messageId"])
            base.require("SENT" in delivered["labels"] and delivered["subject"] == "This week at Ember Studio", "wrong delivered Sent message")
            base.require(receipt["driveFiles"][0]["sharedWith"] == sorted([base.MAYA, base.LEO]), "wrong actual viewers")
            base.require(client.request("cache.stats", base.WORK)["fixtureSends"] == 1, "unexpected mock send count")
        manifest["proofs"]["drive.sent"] = {"receipt": receipt, "delivered": delivered,
            "cameraCells": camera, "linkCells": target, "linkKind": link_kind,
            "fixtureSends": 1, "sourceBytes": artifact.stat().st_size}
        manifest["cleanup"]["drive.sent"] = rec.finish(expected_sends=1, client_extra=story.options())
    finally:
        base.preserve(rec, manifest["buildInfo"], out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--baseline", type=Path, default=base.ROOT / "video/cache/short0218/revision-15/capture-manifest.json")
    parser.add_argument("--takes", default="clear,sent")
    args = parser.parse_args()
    base.reserve()
    binary = args.binary.resolve()
    base.require(hashlib.sha256(binary.read_bytes()).hexdigest() == args.expected_sha256, "published binary changed")
    baseline = json.loads(args.baseline.read_text())
    base.require(baseline["binarySha256"] == args.expected_sha256, "baseline binary differs")
    out = args.out.resolve()
    base.require(not out.exists(), "preserve previous clarity attempt")
    out.mkdir(parents=True)
    manifest = {"schema": "omagma.video.capture.v1", "binarySha256": args.expected_sha256,
        "buildInfo": base.read_build_info(binary), "assets": {}, "proofs": {}, "cleanup": {},
        "synthetic": True, "liveProviderWrites": 0, "userClipboardRead": False,
        "storyDateUtc": datetime.now(timezone.utc).date().isoformat()}
    try:
        for take in args.takes.split(","):
            base.require(take in ("clear", "sent"), "unknown clarity take")
            base.reserve()
            print("CAPTURE " + take, flush=True)
            with tempfile.TemporaryDirectory(prefix="omagma-clarity-" + take + "-") as temporary:
                {"clear": clear, "sent": sent}[take](binary, Path(temporary), out, manifest, baseline)
            base.write_json(out / "capture-manifest.json", manifest)
            print("PASS " + take, flush=True)
    except Exception:
        manifest["failure"] = traceback.format_exc()
        base.write_json(out / "capture-manifest.json", manifest)
        raise


if __name__ == "__main__": main()
