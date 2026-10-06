#!/usr/bin/env python3
"""Print a captured tape's screen as text at chosen marks, or list its marks.

    python3 video/tools/tape_text.py video/cache/capture/tapes/main.json            list marks
    python3 video/tools/tape_text.py video/cache/capture/tapes/main.json read:smoke  screen at a mark
"""
import json
import sys


def screens(tape):
    rows = None
    for frame in tape["frames"]:
        rows = [runs if runs is not None else rows[y] for y, runs in enumerate(frame["rows"])] if rows else [r or [] for r in frame["rows"]]
        yield frame["t"], rows


def text(rows, columns):
    lines = []
    for runs in rows:
        line = [" "] * columns
        for x, chars, _style, cells in runs:
            if cells == len(chars):
                line[x:x + cells] = list(chars)
            else:
                line[x] = chars
                if cells == 2 and x + 1 < columns:
                    line[x + 1] = ""
        lines.append("".join(line).rstrip())
    return "\n".join(lines)


def main():
    tape = json.load(open(sys.argv[1]))
    if len(sys.argv) == 2:
        for mark in tape["marks"]:
            extra = mark.get("keys") or mark.get("typed") or mark.get("click") or ""
            print(f"{mark['t']:7.3f}  frame {mark['frame']:4d}  {mark['name']}  {json.dumps(extra, ensure_ascii=False) if extra else ''}")
        return
    frames = list(screens(tape))
    for name in sys.argv[2:]:
        mark = next(m for m in tape["marks"] if m["name"] == name)
        index = max(i for i, (t, _) in enumerate(frames) if t <= mark["t"] + 1e-9)
        print(f"=== {name} at {mark['t']:.3f} s (frame {index})")
        print(text(frames[index][1], tape["columns"]))


if __name__ == "__main__":
    main()
