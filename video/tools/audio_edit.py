#!/usr/bin/env python3
"""Render a cut map's soundtrack edit from the source song.

    python3 video/tools/audio_edit.py --cut video/tracks/<song>.json --out video/cache/<song>.wav [--raw]

The cut map's "audio" block lists source segments [in, out] (seconds of the
source song) and one equal-power crossfade length. Consecutive segments
overlap by that length, so each seam's incoming downbeat keeps its full attack.
Only the first audio stream is used (-map 0:a:0, -vn: embedded cover art is
ignored) and output metadata is stripped. Without --raw, loudness is
normalised in two passes to -14 LUFS integrated / -1.5 dBTP (linear gain when
possible). The source file must match the recorded SHA-256.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parents[1]


def graph(segments, crossfade):
    parts = [f"[0:a:0]aresample=48000,asplit={len(segments)}" + "".join(f"[s{i}]" for i in range(len(segments)))]
    for i, (start, end) in enumerate(segments):
        parts.append(f"[s{i}]atrim=start={start}:end={end},asetpts=PTS-STARTPTS[a{i}]")
    last = "a0"
    for i in range(1, len(segments)):
        parts.append(f"[{last}][a{i}]acrossfade=d={crossfade}:c1=qsin:c2=qsin[x{i}]")
        last = f"x{i}"
    return ";".join(parts), last


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cut", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--audio", type=Path, help="source song (default: the cut map's audio.source under video/)")
    parser.add_argument("--raw", action="store_true", help="write the unnormalised edit (for analysis)")
    args = parser.parse_args()
    cut = json.loads(args.cut.read_text())
    spec = cut["audio"]
    source = args.audio or HERE / spec["source"]
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != spec["sha256"]:
        raise SystemExit(f"audio_edit: {source.name} does not match the cut map's SHA-256")
    segments = [(float(a), float(b)) for a, b in spec["segments"]]
    crossfade = float(spec["crossfade"])
    expected = sum(b - a for a, b in segments) - crossfade * (len(segments) - 1)
    if abs(expected - cut["duration"]) > 0.002:
        raise SystemExit(f"audio_edit: segments give {expected:.3f} s but the cut map says {cut['duration']} s")
    body, last = graph(segments, crossfade)
    common = ["ffmpeg", "-hide_banner", "-nostats", "-y", "-i", str(source)]
    if args.raw:
        subprocess.run([*common, "-filter_complex", body, "-map", f"[{last}]", "-vn", "-map_metadata", "-1",
                        "-c:a", "pcm_s24le", str(args.out)], check=True, capture_output=True)
        print(f"audio_edit: raw edit {expected:.3f} s -> {args.out.name}")
        return
    target = "I=-14:TP=-1.5:LRA=20"
    first = subprocess.run([*common, "-filter_complex", f"{body};[{last}]loudnorm={target}:print_format=json[n]", "-map", "[n]",
                            "-vn", "-f", "null", "-"], capture_output=True, text=True)
    measured = json.loads(re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", first.stderr).group(0))
    norm = (f"loudnorm={target}:measured_I={measured['input_i']}:measured_TP={measured['input_tp']}:"
            f"measured_LRA={measured['input_lra']}:measured_thresh={measured['input_thresh']}:"
            f"offset={measured['target_offset']}:linear=true:print_format=json")
    second = subprocess.run([*common, "-filter_complex", f"{body};[{last}]{norm},aresample=48000[n]", "-map", "[n]", "-vn",
                             "-map_metadata", "-1", "-c:a", "pcm_s24le", str(args.out)], capture_output=True, text=True)
    if second.returncode:
        raise SystemExit(second.stderr[-2000:])
    result = json.loads(re.search(r"\{[^{}]*\"output_i\"[^{}]*\}", second.stderr).group(0))
    summary = {"duration": round(expected, 3), "input_i": result["input_i"], "input_tp": result["input_tp"],
               "output_i": result["output_i"], "output_tp": result["output_tp"], "normalization_type": result["normalization_type"]}
    args.out.with_suffix(".loudness.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(f"audio_edit: {expected:.3f} s, {result['input_i']} -> {result['output_i']} LUFS, {result['output_tp']} dBTP, "
          f"{result['normalization_type']} -> {args.out.name}")


if __name__ == "__main__":
    sys.exit(main())
