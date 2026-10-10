#!/usr/bin/env bash
# Independent media/dev tooling; no installed application runtime uses this.
set -euo pipefail
cd "$(dirname "$0")/../.."
stage="${1:-film}"
case "$stage" in
  capture|all)
    : "${OMAGMA:?Set OMAGMA to the verified capture executable}"
    : "${OMAGMA_SHA256:?Set OMAGMA_SHA256 to its exact hash}"
    python3 video/short027/capture.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
    python3 video/short027/capture_bar.py --binary "$OMAGMA"
    python3 video/short027/capture_labels.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
    python3 video/short027/capture_palette.py --expected-sha256 "$OMAGMA_SHA256"
    node video/short027/capture-images.mjs
    ;;
  film|brisk|nine|motion|check) ;;
  *) echo 'Usage: video/short027/build.sh [capture|film|brisk|nine|motion|all|check]' >&2; exit 2 ;;
esac
if [[ "$stage" == film || "$stage" == all ]]; then
  node video/short027/render.mjs
  python3 video/short027/encode.py
fi
if [[ "$stage" == brisk ]]; then
  node video/short027/render.mjs --film film-brisk.html --plan video/short027/soundtrack-brisk.json --out video/cache/short027/brisk-polished-frames
  python3 video/short027/encode.py --plan video/short027/soundtrack-brisk.json --frames video/cache/short027/brisk-polished-frames --picture-source video/short027/film-brisk.html --out video/out/omagma-v0.2.7-brisk-polished.mp4
fi
if [[ "$stage" == nine ]]; then
  python3 video/short027/convert_updates.py
  node video/short027/capture-images.mjs --tape updates
  node video/short027/render.mjs --film film-nine.html --plan video/short027/soundtrack-nine.json --out video/cache/short027/nine-frames
  python3 video/short027/encode.py --plan video/short027/soundtrack-nine.json --frames video/cache/short027/nine-frames --picture-source video/short027/film-nine.html --out video/out/omagma-v0.2.7-nine.mp4
fi
if [[ "$stage" == motion ]]; then
  node video/short027/render.mjs --film film-motion.html --plan video/short027/soundtrack-motion.json --out video/cache/short027/motion-frames
  python3 video/short027/encode.py --plan video/short027/soundtrack-motion.json --frames video/cache/short027/motion-frames --picture-source video/short027/film-motion.html --out video/out/omagma-v0.2.7-motion.mp4
fi
if [[ "$stage" == check ]]; then
  node --check video/short027/cdp.mjs
  node --check video/short027/render.mjs
  node --check video/short027/capture-images.mjs
  node --check video/short027/capture_cdp.mjs
  node --check video/short027/qa.mjs
  node --check video/short027/qa-motion.mjs
  node --check video/short027/review-motion.mjs
  python3 -m py_compile video/short027/capture.py video/short027/capture_bar.py video/short027/capture_labels.py video/short027/capture_forward_story.py video/short027/capture_fixture.py video/short027/encode.py video/short027/deliver.py video/short027/preview.py video/short027/convert_updates.py
fi
