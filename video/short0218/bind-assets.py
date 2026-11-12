#!/usr/bin/env python3
"""Bind Opus's named cameras/spotlights to exact captured cells and DOM rects.

No application, browser, image or tape is changed. Camera rectangles include
context; rois with the same name may be tighter spotlight rectangles. Originals
and a complete anchor/geometry receipt are preserved before the manifest write.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def union(*rectangles):
    rectangles = [r for r in rectangles if r is not None]
    require(bool(rectangles), "empty anchor union")
    x = min(r[0] for r in rectangles)
    y = min(r[1] for r in rectangles)
    return [x, y, max(r[0] + r[2] for r in rectangles) - x,
            max(r[1] + r[3] for r in rectangles) - y]


class Frame:
    def __init__(self, tape, index):
        self.columns, self.rows = tape["columns"], tape["rows"]
        self.grid = [[" "] * self.columns for _ in range(self.rows)]
        self.styles = [[None] * self.columns for _ in range(self.rows)]
        current = None
        for frame in tape["frames"][:index + 1]:
            current = frame["rows"] if current is None else [new if new is not None else old
                       for new, old in zip(frame["rows"], current)]
        require(current is not None, "missing captured frame")
        for y, row in enumerate(current):
            for x, text, style, width in row:
                if len(text) == width:
                    for offset, char in enumerate(text):
                        self.grid[y][x + offset] = char
                else:
                    self.grid[y][x] = text
                    for offset in range(1, width):
                        self.grid[y][x + offset] = ""
                for offset in range(width):
                    self.styles[y][x + offset] = tape["styles"][style]
        self.cursor = tape["frames"][index].get("cursor")
        self.anchors = {}
        self.exceptions = []

    def text(self, y, left=0, right=None):
        return "".join(self.grid[y][left:right])

    def find(self, literal, *, left=0, right=None, required=True):
        right = self.columns if right is None else right
        for y in range(self.rows):
            for x in range(left, right):
                if not "".join(self.grid[y][x:right]).startswith(literal):
                    continue
                end, emitted = x, ""
                while end < right and len(emitted) < len(literal):
                    emitted += self.grid[y][end]
                    end += 1
                while end < right and self.grid[y][end] == "":
                    end += 1
                result = [x, y, end - x, 1]
                self.anchors[literal] = result
                return result
        require(not required, "required captured anchor absent: " + literal)
        return None

    def pane(self, anchor):
        x, y = anchor[:2]
        choices = []
        for top in range(y + 1):
            for left in range(x + 1):
                if self.grid[top][left] not in ("╭", "┌"):
                    continue
                right = next((r for r in range(left + 1, self.columns)
                              if self.grid[top][r] in ("╮", "┐")), None)
                bottom = next((b for b in range(top + 1, self.rows)
                               if self.grid[b][left] in ("╰", "└")), None)
                if (right is not None and bottom is not None and right >= x and bottom >= y
                        and self.grid[bottom][right] in ("╯", "┘")):
                    # Occluded background panels can retain all four corners.
                    # Require the actual uninterrupted vertical borders too.
                    if all(self.grid[row][left] == "│" and self.grid[row][right] == "│"
                           for row in range(top + 1, bottom)):
                        choices.append([left, top, right - left + 1, bottom - top + 1])
        require(bool(choices), "captured pane corners absent around anchor")
        return min(choices, key=lambda r: r[2] * r[3])

    def clamp(self, rect):
        x, y, width, height = rect
        width, height = min(width, self.columns), min(height, self.rows)
        return [max(0, min(x, self.columns - width)), max(0, min(y, self.rows - height)), width, height]

    def camera(self, content, *, width=90, height=20, x=None, y=None):
        actual_width, actual_height = max(width, content[2]), max(height, content[3])
        if actual_width > width or actual_height > height:
            self.exceptions.append({"intentCells": [width, height],
                                    "requiredToIncludeActualAnchors": content,
                                    "actualCells": [actual_width, actual_height]})
        left = content[0] + (content[2] - actual_width) / 2 if x is None else x
        top = content[1] + (content[3] - actual_height) / 2 if y is None else y
        result = self.clamp([math.floor(left), math.floor(top), actual_width, actual_height])
        require(result[0] <= content[0] and result[1] <= content[1]
                and result[0] + result[2] >= content[0] + content[2]
                and result[1] + result[3] >= content[1] + content[3], "camera clips its required anchors")
        return result

    def normalized(self, rect):
        x, y, width, height = rect
        return [x / self.columns, y / self.rows, width / self.columns, height / self.rows]


def native_bind(key, frame, entry):
    rois, cameras = {}, {}
    if key.startswith("clipboard."):
        body = frame.find("MD · Body:", right=frame.columns * 3 // 5)
        first = frame.find("Hi Maya, here's the new mark for slide one:", right=frame.columns * 3 // 5)
        signature = frame.find("Ember Studio", left=0, right=frame.columns * 3 // 5)
        region = [0, body[1], frame.columns * 3 // 5, signature[1] - body[1] + 1]
        cameras["body"] = frame.camera(region, x=0, y=max(0, body[1] - 3))
        rois["body"] = cameras["body"]
        rois["cursor"] = first
        if frame.cursor:
            entry.setdefault("targets", {})["cursor"] = [(frame.cursor[0] + .5) / frame.columns,
                                                          (frame.cursor[1] + .5) / frame.rows]
        marker = frame.find("![clipboard-", right=frame.columns * 3 // 5, required=False)
        if marker:
            last = frame.find("@omagma.invalid)", right=frame.columns * 3 // 5)
            rois["marker"] = [marker[0], marker[1], frame.columns * 3 // 5 - marker[0] - 1,
                              last[1] - marker[1] + 1]
    elif key == "booking.mail":
        header = frame.find("From: Ember Studio")
        title = frame.find("Haircut", left=header[0])
        location = frame.find("12 Example Street", left=header[0])
        rois["card"] = [header[0], title[1], frame.columns - header[0] - 1, location[1] - title[1] + 1]
        content = union([header[0] - 2, header[1] - 2, 2, 1], rois["card"])
        cameras["reader"] = frame.camera(content, width=80, x=frame.columns - 80)
        rois["reader"] = cameras["reader"]
    elif key in ("booking.review", "booking.complete"):
        modal = frame.pane(frame.find("Add to calendar"))
        expanded = frame.clamp([modal[0] - 1, modal[1] - 1, modal[2] + 2, modal[3] + 2])
        if key.endswith("review"):
            rois["modal"] = expanded
            cameras["modal"] = expanded
            rois["add"] = frame.find("[y Add appointment]")
        else:
            status = frame.find("Added to your primary calendar. No email sent.")
            rois["status"] = status
            rois["result"] = cameras["result"] = expanded
    elif key in ("calendar.now", "calendar.week"):
        now = frame.find("now")
        today_header = next(y for y in range(now[1]) if any(day in frame.text(y)
                            for day in ("Mon ", "Tue ", "Wed ", "Thu ", "Fri ", "Sat ", "Sun ")))
        underlined = [x for x, style in enumerate(frame.styles[now[1]])
                      if style and style[2] & 4 and len(style) > 3 and style[3] is not None]
        require(bool(underlined), "native red underline metadata missing")
        rois["nowRow"] = [0, now[1], max(underlined) + 1, 1]
        haircut = frame.find("Haircut")
        require(haircut[0] < 70, "booking is outside the authored today/neighbor crop")
        content = union([0, today_header, 70, 1], rois["nowRow"], haircut)
        cameras["hero"] = frame.camera(content, width=70, x=0)
        rois["hero"] = cameras["hero"]
    elif key == "drive.picker":
        file = frame.find("launch-film-master.mov")
        pane = frame.pane(file)
        cameras["picker"] = rois["picker"] = pane
        if pane[2] > 90:
            frame.exceptions.append({"intentMaxColumns": 90, "actualColumns": pane[2],
                                     "reason": "Preserve the complete actual picker border and all file sizes"})
        rois["file"] = [pane[0] + 1, file[1], pane[2] - 2, 1]
    elif key == "drive.choice":
        pane = frame.pane(frame.find("Too large to attach"))
        cameras["modal"] = frame.camera(pane, width=80)
        rois["modal"] = cameras["modal"]
        rois["options"] = union(frame.find("[ Auto (a) ]"), frame.find("[ Drive all (d) ]"), frame.find("[ Keep (k) ]"))
    elif key == "drive.selected":
        file = frame.find("launch-film-master.mov", right=frame.columns * 3 // 5)
        delivery = frame.find("[Drv     ]")
        tail = frame.find("Morgan Hills", right=frame.columns * 3 // 5)
        rois["drive"] = [1, file[1], frame.columns * 3 // 5 - 2, delivery[1] - file[1] + 1]
        cameras["attachments"] = frame.camera(union(tail, rois["drive"]), x=0, y=frame.rows - 20)
        rois["attachments"] = cameras["attachments"]
    elif key == "drive.review":
        account = frame.find("Sending account:")
        uploaded = frame.find("From Drive 1")
        content = union(account, uploaded)
        cameras["top"] = frame.camera(content, x=0)
        rois["top"] = cameras["top"]
    elif key == "drive.access" or key.startswith("drive.access-scroll-"):
        viewers = frame.find("Viewer-only access for exactly:", required=False)
        restricted = frame.find("Restricted link", required=False)
        if viewers and restricted:
            # Measure the actual full recipient and policy text, not the pane's
            # trailing blank cells, for the narrow emphasis rectangle.
            viewers = frame.find("Viewer-only access for exactly: maya@example.org, leo@example.net")
            restricted = frame.find("Restricted link · no Drive notification · others can't open it.")
            rois["access"] = union(viewers, restricted)
            cameras["access"] = frame.camera(rois["access"], x=0, y=frame.rows - 20)
        elif key == "drive.access":
            raise AssertionError("final access bitmap lacks actual viewer/restricted rows")
        else:
            cameras["access"] = frame.camera([1, 13, 88, 14], x=0)
            rois["access"] = cameras["access"]
    elif key.startswith("drive.countdown"):
        line = frame.find("Sending in ")
        # Anchor the actual banner text, including both controls, rather than
        # trailing blank cells outside the contextual camera.
        end = max(x + 1 for x, cell in enumerate(frame.grid[line[1]]) if cell.strip())
        rois["countdown"] = [line[0], line[1], end - line[0], 1]
        cameras["countdown"] = frame.camera(rois["countdown"], x=0, y=0)
    elif key.startswith("drive.progress") or key == "drive.upload":
        progress = frame.find("uploading ")
        pane = frame.pane(progress)
        cameras["progress"] = frame.camera(pane)
        rois["progress"] = cameras["progress"]
        rois["progressLine"] = [pane[0] + 1, progress[1], pane[2] - 2, 1]
    elif key == "drive.complete":
        status = frame.find("Send complete · provider accepted")
        rois["status"] = status
        cameras["result"] = frame.camera(status, x=0, y=frame.rows - 20)
        rois["result"] = cameras["result"]
    elif key.startswith("meet."):
        if key in ("meet.unchecked", "meet.checked"):
            label = "[ ] Auto Meet AI notes" if key.endswith("unchecked") else "[x] Auto Meet AI notes"
            checkbox = frame.find(label)
            title = frame.find("New event")
            pane = frame.pane(checkbox)
            notes = frame.find("Notes:")
            content = [pane[0], title[1], pane[2], notes[1] - title[1] + 1]
            cameras["form"] = frame.camera(content)
            rois["form"] = cameras["form"]
            rois["checkbox"] = [checkbox[0], checkbox[1], len("[ ] Auto Meet AI notes + transcript"), 1]
        elif key == "meet.review":
            title = frame.find("Review new event")
            confirm = frame.find("[y Create event]")
            pane = frame.pane(title)
            content = [pane[0], title[1], pane[2], confirm[1] - title[1] + 1]
            cameras["review"] = frame.camera(content)
            rois["review"] = cameras["review"]
            rois["confirm"] = confirm
        elif key == "meet.complete":
            status = frame.find("Saved in Calendar. Meet AI notes + transcript: on, confirmed by Google")
            title = frame.find("Event saved")
            last = frame.find("Meet.")
            pane = frame.pane(title)
            rois["result"] = [status[0], status[1], pane[0] + pane[2] - status[0] - 1, last[1] - status[1] + 1]
            cameras["result"] = frame.camera([pane[0], title[1], pane[2], last[1] - title[1] + 1])
    require(bool(rois), "unhandled native asset: " + key)
    entry.setdefault("rois", {}).update({name: frame.normalized(rect) for name, rect in rois.items()})
    entry["cameraRois"] = {name: frame.normalized(rect) for name, rect in cameras.items()}
    return {"anchors": frame.anchors, "cellRois": rois, "cellCameras": cameras,
            "geometryExceptions": frame.exceptions}


def browser_bind(entry):
    content = entry["contentProof"]
    before, after = content["textRects"]
    image = next(image for image in content["images"] if image["alt"])
    css_width, css_height = entry["width"] / 2, entry["height"] / 2
    # The original raster receipt's content rectangle is the measured iframe.
    iframe_x, iframe_y = entry["rois"]["content"][0] * css_width, entry["rois"]["content"][1] * css_height
    def parent_rect(rect):
        return [iframe_x + rect["x"], iframe_y + rect["y"], rect["width"], rect["height"]]
    ingredients = union(parent_rect(before), parent_rect(image["rect"]), parent_rect(after))
    x, y, width, height = ingredients
    width, height = width + 40, height + 40
    # Expand only to the authored frame's aspect; retain DOM geometry/content.
    ratio = 1680 / 760
    width = max(width, height * ratio)
    height = max(height, width / ratio)
    x = max(0, min(x + ingredients[2] / 2 - width / 2, css_width - width))
    y = max(0, min(y + ingredients[3] / 2 - height / 2, css_height - height))
    focus = [x / css_width, y / css_height, width / css_width, height / css_height]
    rect = parent_rect(image["rect"])
    entry["rois"].update(focus=focus, image=[rect[0] / css_width, rect[1] / css_height,
                                          rect[2] / css_width, rect[3] / css_height])
    entry["cameraRois"] = {"focus": focus}
    scale = min(1680 / width, 760 / height)
    require(image["rect"]["width"] * scale >= 220 and min(before["height"], after["height"]) * scale >= 26,
            "actual browser ingredients would be too small")
    return {"iframeCssOffset": [iframe_x, iframe_y], "ingredientCssBounds": ingredients,
            "focusCssBounds": [x, y, width, height], "pastedImageApparentPx": image["rect"]["width"] * scale,
            "textGlyphApparentPx": min(before["height"], after["height"]) * scale}


def valid(rect):
    return (len(rect) == 4 and all(math.isfinite(v) for v in rect) and min(rect) >= 0
            and rect[2] > 0 and rect[3] > 0 and rect[0] + rect[2] <= 1.000001 and rect[1] + rect[3] <= 1.000001)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--plan", type=Path, default=ROOT / "video/short0218/film-plan.json")
    parser.add_argument("--source-manifest", type=Path)
    parser.add_argument("--attempt", default="01")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    require(args.revision.startswith("revision-") and args.revision[9:].isdigit(), "owned revision required")
    root = ROOT / "video/cache/short0218" / args.revision
    path = root / "assets-manifest.json"
    require(args.attempt.isdigit(), "numeric binding attempt required")
    original = (args.source_manifest or path).read_bytes()
    manifest = json.loads(original)
    plan = json.loads(args.plan.read_text())
    require("namedRois" in plan["assetRequirements"], "missing actual Opus ROI contract")
    receipt = {"schema": "omagma.video.binding.v1", "inputManifestSha256": hashlib.sha256(original).hexdigest(),
               "planSha256": digest(args.plan), "assets": {}, "aliases": {}, "unchangedImageHashes": {}}
    tapes = {}
    for key, entry in manifest["assets"].items():
        file = ROOT / entry["file"].lstrip("/") if entry["file"].startswith("/") else root / entry["file"]
        require(digest(file) == entry["sha256"], "raster bytes changed: " + key)
        receipt["unchangedImageHashes"][key] = entry["sha256"]
        if "tape" in entry:
            tape_path = root / entry["tape"]
            require(digest(tape_path) == entry["tapeSha256"], "captured tape changed: " + key)
            tape = tapes.setdefault(entry["tape"], json.loads(tape_path.read_text()))
            frame = Frame(tape, entry["frame"])
            receipt["assets"][key] = native_bind(key, frame, entry)
            box = plan["layout"]["frameBox"]["meet" if key.startswith("meet.") else "default"]
            receipt["assets"][key]["cameraApparentFontPx"] = {
                name: (entry["width"] / frame.columns / .6)
                * min(box[2] / (rect[2] * entry["width"]), box[3] / (rect[3] * entry["height"]))
                for name, rect in entry.get("cameraRois", {}).items()}
            if key == "meet.unchecked":
                click = next(mark for mark in tape["marks"] if mark["name"] == "meet.enable-notes" and "click" in mark)
                x, y = click["click"]
                require(frame.find("[ ] Auto Meet AI notes")[1] == y, "recorded click is not on checkbox")
                entry.setdefault("targets", {})["click"] = [(x + .5) / frame.columns, (y + .5) / frame.rows]
                receipt["assets"][key]["recordedClick"] = click
        elif key == "browser.inline":
            receipt["assets"][key] = browser_bind(entry)
    for key in list(manifest["assets"]):
        alias = None
        if key.startswith("clipboard.typing-"):
            alias = "clipboard.typing" + str(int(key.rsplit("-", 1)[1]))
        elif key.startswith("drive.progress-"):
            alias = "drive.progress" + str(int(key.rsplit("-", 1)[1]))
        if alias:
            require(alias not in manifest["assets"], "canonical alias already exists")
            manifest["assets"][alias] = copy.deepcopy(manifest["assets"][key])
            manifest["assets"][alias]["aliasOf"] = key
            receipt["aliases"][alias] = key
    for key, entry in manifest["assets"].items():
        for group in ("rois", "cameraRois"):
            for name, rect in entry.get(group, {}).items():
                require(valid(rect), "invalid normalized geometry: " + key + "." + group + "." + name)
        for name, point in entry.get("targets", {}).items():
            require(len(point) == 2 and all(0 <= v <= 1 for v in point), "invalid click/cursor target")
    receipt["assetCount"] = len(manifest["assets"])
    encoded = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
    receipt["outputManifestSha256"] = hashlib.sha256(encoded).hexdigest()
    if not args.dry_run:
        suffix = "" if args.attempt == "01" else "-" + args.attempt
        backup = root / ("assets-manifest.before-binding" + suffix + ".json")
        require(not backup.exists(), "preserve previous binding attempt")
        backup.write_bytes(path.read_bytes())
        receipt_path = root / "asset-binding-receipt.json"
        if receipt_path.exists():
            old_receipt = root / ("asset-binding-receipt.before" + suffix + ".json")
            require(not old_receipt.exists(), "preserve previous binding receipt")
            old_receipt.write_bytes(receipt_path.read_bytes())
        path.write_bytes(encoded)
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print("PASS " + ("dry-run " if args.dry_run else "") + "actual asset bindings: "
          + str(len(manifest["assets"])) + " assets, " + str(len(receipt["aliases"])) + " canonical aliases")


if __name__ == "__main__":
    main()
