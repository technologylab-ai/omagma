#!/usr/bin/env bash
# Builds Omagma's launch film: real fictional-fixture captures, cut to a measured song.
#
#   video/build.sh check   [CUT]          validate the tooling and a cut map (cheap)
#   video/build.sh analyze AUDIO          measure a song -> video/tracks/<song>.analysis.json [heavy]
#   video/build.sh capture                record the real TUI takes, bar states and CLI cameo  [heavy]
#   video/build.sh sheet   CUT            stills at every scene's start/middle/end            [heavy]
#   video/build.sh draft   CUT [AUDIO]    half-size labelled review video                     [heavy]
#   video/build.sh film    CUT AUDIO      1920x1080 30 fps master, poster and report          [heavy]
#   video/build.sh preview CUT            loopback scrub preview for a browser
#
# Heavy steps run only inside the cooperative host reservation (docs/VERIFICATION.md):
# HOST_TOKEN=<token held by your coordinator>, or RESERVE=1 to take and release it here.
#
# Environment: OMAGMA (binary; default zig-out/bin/omagma), OMAGMA_SHA256 (expected
# executable hash), LOGO_MASTER (high-resolution copy of the approved logo, installed
# as video/cache/logo-master.png), FPS (30), CRF (18), WORKERS (render pages), OUT
# (video/out/<cut>.mp4). Needs node 24+, Chromium, ffmpeg/ffprobe with libx264,
# ImageMagick, python3, Quickshell (bar capture) and uv (analysis). See video/README.md.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
cache=$here/cache
FPS=${FPS:-30}
OWN_LOCK=
die() { echo "build: $*" >&2; exit 1; }
note() { echo "== $*"; }
jget() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); [v:=v[k] for k in sys.argv[2:]]; print(v)' "$@"; }

release() {
  if [ -n "$OWN_LOCK" ]; then python3 "$here/tools/host_lock.py" release "$HOST_TOKEN" && echo "== host reservation released"; fi
}
reserve() {
  if [ -n "${HOST_TOKEN:-}" ]; then
    python3 "$here/tools/host_lock.py" verify "$HOST_TOKEN" || die "HOST_TOKEN does not match the held host reservation"
  elif [ -n "${RESERVE:-}" ]; then
    HOST_TOKEN=$(python3 "$here/tools/host_lock.py" acquire --pid $$) || die "host reservation is busy; coordinate with its owner"
    OWN_LOCK=1
    trap release EXIT
    note "host reservation acquired"
  else
    die "this step is heavy: set HOST_TOKEN=<coordinator token> or RESERVE=1 (see video/README.md)"
  fi
}
binary() {
  OMAGMA=${OMAGMA:-$repo/zig-out/bin/omagma}
  [ -x "$OMAGMA" ] || die "no executable at $OMAGMA (set OMAGMA)"
  local sha; sha=$(sha256sum "$OMAGMA" | cut -d' ' -f1)
  [ -z "${OMAGMA_SHA256:-}" ] || [ "$sha" = "$OMAGMA_SHA256" ] || die "executable hash $sha differs from OMAGMA_SHA256"
  note "executable: $("$OMAGMA" --version) sha256 ${sha:0:16}…"
}
logo() {
  mkdir -p "$cache"
  if [ -n "${LOGO_MASTER:-}" ]; then
    install -m 600 "$LOGO_MASTER" "$cache/logo-master.png"
  elif [ ! -f "$cache/logo-master.png" ] && [ -f "$here/assets/omagma-logo-master.png" ]; then
    install -m 600 "$here/assets/omagma-logo-master.png" "$cache/logo-master.png"
  fi
  [ -f "$cache/logo-master.png" ] || echo "build: note: no video/cache/logo-master.png; the 120 px asset will look soft at hero size (set LOGO_MASTER)" >&2
}
cutname() { basename "$1" .json; }
check_cut() { node "$here/tools/check.mjs" "$@"; }

render() { # CUT [render.mjs options]
  local cut=$1; shift
  node "$here/render.mjs" --cut "$cut" --fps "$FPS" ${WORKERS:+--workers "$WORKERS"} "$@"
}

# Soundtrack: a cut map with "audio.segments" is a montage of the source song,
# rendered by tools/audio_edit.py (seams, crossfades, two-pass -14 LUFS / -1.5 dBTP).
# Otherwise a continuous section from audio_offset is normalised the same way.
audio() { # CUT AUDIO OUT.wav
  local cut=$1 src=$2 wav=$3 off dur len pre measured
  if python3 -c 'import json,sys; sys.exit(0 if "audio" in json.load(open(sys.argv[1])) else 1)' "$cut"; then
    python3 "$here/tools/audio_edit.py" --cut "$cut" --audio "$src" --out "$wav"
    return
  fi
  dur=$(jget "$cut" duration); off=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("audio_offset", 0))' "$cut")
  len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
  pre="aresample=48000"
  # Only a section cut from inside a longer song gets a short fade; a natural ending is kept.
  if python3 -c 'import sys; a,o,d=map(float,sys.argv[1:]); sys.exit(0 if a-o > d+0.3 else 1)' "$len" "$off" "$dur"; then
    pre="$pre,afade=t=out:st=$(python3 -c "print(max(0, $dur - 1.2))"):d=1.2"
    note "audio: section ends inside the song; 1.2 s fade added"
  fi
  measured=$(ffmpeg -hide_banner -nostats -ss "$off" -t "$dur" -i "$src" -map 0:a:0 -vn -af "$pre,loudnorm=I=-14:TP=-1.5:LRA=20:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
  local get="import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])"
  local norm="loudnorm=I=-14:TP=-1.5:LRA=20:measured_I=$(python3 -c "$get" input_i <<<"$measured"):measured_TP=$(python3 -c "$get" input_tp <<<"$measured")"
  norm="$norm:measured_LRA=$(python3 -c "$get" input_lra <<<"$measured"):measured_thresh=$(python3 -c "$get" input_thresh <<<"$measured")"
  norm="$norm:offset=$(python3 -c "$get" target_offset <<<"$measured"):linear=true:print_format=json"
  ffmpeg -hide_banner -nostats -y -ss "$off" -t "$dur" -i "$src" -map 0:a:0 -vn -map_metadata -1 -af "$pre,$norm,aresample=48000" -c:a pcm_s24le "$wav" 2>"$wav.log"
  note "audio: $(sed -n '/^{/,/^}/p' "$wav.log" | python3 -c 'import json,sys; v=json.load(sys.stdin); print("input {} LUFS -> {} LUFS, {} dBTP, {}".format(v["input_i"], v["output_i"], v["output_tp"], v["normalization_type"]))')"
}

encode() { # FRAMES_DIR AUDIO_WAV OUT CRF [scale]
  local frames=$1 wav=$2 out=$3 crf=$4 ext
  ext=$(python3 - "$frames" <<'PY'
from pathlib import Path
import sys
images = sorted(p for p in Path(sys.argv[1]).iterdir() if p.suffix in {".jpg", ".png"} and p.stem.isdigit())
if not images:
    raise SystemExit("encode: no numbered image frames")
print(images[0].suffix)
PY
)
  ffmpeg -hide_banner -loglevel error -y -framerate "$FPS" -i "$frames/%05d$ext" -i "$wav" \
    -vf "scale=in_color_matrix=bt601:in_range=pc:out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
    -c:v libx264 -preset slow -crf "$crf" -maxrate 14M -bufsize 28M -profile:v high -g $((FPS * 2)) -x264-params aq-mode=3 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv -r "$FPS" \
    -c:a aac -b:a 256k -ar 48000 -shortest -map_metadata -1 -map_chapters -1 -fflags +bitexact -movflags +faststart "$out"
}

report() { # OUT EXPECTED_FRAMES
  local out=$1 expected=$2 json=${1%.mp4}.report.json
  python3 - "$out" "$expected" "$json" "$FPS" <<'EOF'
import json, re, subprocess, sys
out, expected, path, fps = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
    "format=duration,size,bit_rate:stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,nb_read_frames,duration,sample_rate,channels,color_space,color_range",
    "-of", "json", out], capture_output=True, text=True, check=True).stdout)
log = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", out, "-map", "0:a", "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
summary = log[log.rfind("Summary:"):]
grab = lambda label: float(re.search(r"\b" + label + r":\s+(-?[\d.]+)", summary).group(1))
video = next(s for s in probe["streams"] if s["codec_name"] == "h264")
audio = next(s for s in probe["streams"] if s["codec_name"] == "aac")
report = {"file": out.rsplit("/", 1)[-1], "bytes": int(probe["format"]["size"]), "duration": float(probe["format"]["duration"]),
          "video": video, "audio": audio, "frames": int(video["nb_read_frames"]), "expected_frames": expected,
          "loudness": {"integrated_lufs": grab("I"), "true_peak_dbtp": grab("Peak"), "range_lu": grab("LRA")}}
json.dump(report, open(path, "w"), indent=1)
ok = report["frames"] == expected and abs(report["duration"] - expected / fps) < 0.1 and abs(report["loudness"]["integrated_lufs"] + 14) <= 1 and report["loudness"]["true_peak_dbtp"] <= -1.0
print(f"== {report['file']}: {video['width']}x{video['height']} {video['pix_fmt']} {video['r_frame_rate']} fps, {report['frames']}/{expected} frames, "
      f"{report['duration']:.3f} s, {report['bytes'] / 1e6:.1f} MB, audio {audio['sample_rate']} Hz x{audio['channels']}, "
      f"{report['loudness']['integrated_lufs']} LUFS, {report['loudness']['true_peak_dbtp']} dBTP -> {'ok' if ok else 'CHECK'}")
sys.exit(0 if ok else 1)
EOF
}

cmd=${1:-}; shift || true
case "$cmd" in
  check)
    note "syntax"
    for f in "$here"/web/*.js "$here"/*.mjs "$here"/tools/*.mjs; do node --check "$f"; done
    PYTHONPYCACHEPREFIX=$(mktemp -d) python3 -m py_compile "$here"/capture/*.py "$here"/analyze/*.py "$here"/tools/*.py
    bash -n "$0"
    check_cut "${1:-$here/tracks/draft-110.json}"
    ;;
  analyze)
    src=${1:?usage: video/build.sh analyze AUDIO}
    reserve
    name=$(basename "${src%.*}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')
    uv run --no-project --with librosa --with soundfile python "$here/analyze/analyze_track.py" "$src" --out "$here/tracks/$name.analysis.json"
    ;;
  capture)
    reserve; binary
    note "capture: real TUI takes and CLI cameo (owned PTYs, fictional fixtures)"
    python3 "$here/capture/takes.py" --binary "$OMAGMA" --out "$cache/capture" ${TAKES:+--takes "$TAKES"} ${SIZE:+--size "$SIZE"}
    note "capture: bar states (offscreen Quickshell)"
    python3 "$here/capture/bar.py" --binary "$OMAGMA" --out "$cache/capture/bar"
    ;;
  sheet)
    cut=${1:?usage: video/build.sh sheet CUT}; reserve; logo; check_cut "$cut"
    render "$cut" --sheet --scale 0.5
    mkdir -p "$here/out"
    magick montage "$cache/sheet/$(cutname "$cut")"/*.png -label '%t' -tile 6x -geometry 480x270+6+18 -background '#0b0d12' \
      -fill '#c9ccd6' -pointsize 13 "$here/out/$(cutname "$cut")-sheet.png" 2>/dev/null || \
      magick montage "$cache/sheet/$(cutname "$cut")"/*.png -tile 6x -geometry 480x270+6+6 -background '#0b0d12' "$here/out/$(cutname "$cut")-sheet.png"
    note "sheet: video/out/$(cutname "$cut")-sheet.png"
    ;;
  draft)
    cut=${1:?usage: video/build.sh draft CUT [AUDIO]}; reserve; logo; check_cut "$cut"
    name=$(cutname "$cut")
    src=${2:-}
    if [ -z "$src" ]; then
      src=$here/$(jget "$cut" track file)
      if [ ! -f "$src" ] && [ "$(jget "$cut" kind)" = draft ]; then node "$here/synth.mjs" "$src"; fi
    fi
    [ -f "$src" ] || die "no audio at $src"
    render "$cut" --scale 0.5 --out "$cache/frames/$name-draft" --label "DRAFT · $(jget "$cut" kind) cut"
    mkdir -p "$here/out"
    audio "$cut" "$src" "$cache/$name-draft.wav"
    encode "$cache/frames/$name-draft" "$cache/$name-draft.wav" "$here/out/$name-draft.mp4" 24
    note "draft: video/out/$name-draft.mp4"
    ;;
  film)
    cut=${1:?usage: video/build.sh film CUT AUDIO}; src=${2:?usage: video/build.sh film CUT AUDIO}
    reserve; logo
    [ "$(jget "$cut" kind)" = measured ] || [ -n "${ALLOW_DRAFT:-}" ] || die "the film needs a measured cut map (ALLOW_DRAFT=1 overrides)"
    check_cut "$cut" --final
    name=$(cutname "$cut"); OUT=${OUT:-$here/out/omagma-$name.mp4}
    dur=$(jget "$cut" duration)
    note "render: $cut ($dur s at $FPS fps, strict: real captures only)"
    render "$cut" --strict
    mkdir -p "$(dirname "$OUT")"
    audio "$cut" "$src" "$cache/$name.wav"
    note "encode: $OUT"
    encode "$cache/frames/$name" "$cache/$name.wav" "$OUT" "${CRF:-18}"
    render "$cut" --strict --poster --out "$cache/poster/$name"
    cp "$cache/poster/$name/poster.png" "${OUT%.mp4}-poster.png"
    magick "${OUT%.mp4}-poster.png" -quality 90 "${OUT%.mp4}-poster.jpg"
    report "$OUT" "$(python3 -c "print(round($dur * $FPS))")"
    # Each film output keeps the resolved cut times it was rendered from.
    cp "$here/out/$name.cuts.json" "${OUT%.mp4}.cuts.json"
    note "done: $OUT, ${OUT%.mp4}-poster.png, ${OUT%.mp4}.cuts.json"
    ;;
  preview)
    cut=${1:?usage: video/build.sh preview CUT}; logo
    node "$here/render.mjs" --cut "$cut" --preview
    ;;
  *)
    sed -n '2,19p' "$0"; exit 2 ;;
esac
