#!/usr/bin/env python3
"""Write a song's cut map from its measured analysis and an edit plan.

    python3 video/tools/cutmap.py --analysis video/tracks/<song>.analysis.json \
        --plan video/tracks/draft-110.json --landmarks groove=D4,build=D14,drop=D20,ending=D24,final=D25 \
        [--offset 12.31 --end 70.2] --out video/tracks/<song>.json

The plan's scenes are written relative to landmarks (@groove+3, @drop, ...), so
the same edit lands on the new song's measured bars. --offset/--end select a
continuous section of a longer song; every measured time is shifted so the
film starts at 0. The result keeps the actual beat and downbeat arrays, the
analyzer identity and the offset. Review and adjust the scenes afterwards: a
song with a shorter groove or build needs editorial choices, not stretching.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--analysis", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--landmarks", required=True, help="name=D<bar> or name=<seconds>, comma-separated, after the offset")
    parser.add_argument("--offset", type=float, default=0.0, help="song time that becomes film time 0")
    parser.add_argument("--end", type=float, help="song time where the film ends (default: audible end)")
    parser.add_argument("--fade", type=float, help="film time where a final fade to black starts (default: none)")
    parser.add_argument("--title", default="")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    analysis = json.loads(args.analysis.read_text())
    plan = json.loads(args.plan.read_text())
    end = args.end if args.end is not None else analysis["suggested_landmarks"]["audible_end_s"]
    shift = lambda values: [round(v - args.offset, 4) for v in values if args.offset - 1e-3 <= v < end]
    landmarks = {}
    for item in args.landmarks.split(","):
        name, value = item.split("=")
        landmarks[name.strip()] = value.strip() if value.strip().startswith("D") else float(value)
    if args.fade is not None:
        landmarks["fade"] = args.fade
    energy = analysis["energy"]
    first = int(round(args.offset * energy["fps"]))
    last = int(round(end * energy["fps"]))
    cut = {
        "kind": "measured",
        "track": {"title": args.title or analysis["file"], "file": f"cache/music/{analysis['file']}", "sha256": analysis["sha256"],
                  "probe": analysis["probe"], "loudness": analysis["loudness"]},
        "analysis": {**analysis["analyzer"], "source": args.analysis.name, "tempo_bpm": analysis["tempo_bpm"], "beat_s": analysis["beat_s"],
                     "beat_jitter_ms": analysis["beat_jitter_ms"], "plp_agreement": analysis["plp_agreement"],
                     "first_drum_beat": analysis["first_drum_beat"], "downbeat_phase": analysis["downbeat_phase"],
                     "downbeat_scores": analysis["downbeat_scores"], "suggested_landmarks": analysis["suggested_landmarks"]},
        "audio_offset": args.offset,
        "fps": plan.get("fps", 30),
        "duration": round(end - args.offset, 4),
        "beats": shift(analysis["beats"]),
        "downbeats": shift(analysis["downbeats"]),
        "landmarks": landmarks,
        "energy": {"fps": energy["fps"], "source": energy["source"], "values": energy["values"][first:last]},
        "scenes": copy.deepcopy(plan["scenes"]),
    }
    if not cut["beats"] or not cut["downbeats"]:
        raise SystemExit("the selected section contains no measured beats")
    lines = ["{"]
    for key in [k for k in cut if k not in ("scenes", "beats", "downbeats", "energy")]:
        lines.append(f" {json.dumps(key)}: {json.dumps(cut[key], ensure_ascii=False)},")
    for key in ("beats", "downbeats", "energy"):
        lines.append(f" {json.dumps(key)}: {json.dumps(cut[key])},")
    lines.append(' "scenes": [')
    lines.append(",\n".join("  " + json.dumps(scene, ensure_ascii=False) for scene in cut["scenes"]))
    lines.append(" ]\n}")
    args.out.write_text("\n".join(lines) + "\n")
    print(f"cut map: {cut['duration']} s, {len(cut['beats'])} beats, {len(cut['downbeats'])} bars, landmarks {landmarks} -> {args.out}")


if __name__ == "__main__":
    main()
