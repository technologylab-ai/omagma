#!/usr/bin/env bash
# Independent media/dev tooling; no installed application runtime uses this.
set -euo pipefail
cd "$(dirname "$0")/../.."
stage="${1:-film}"
case "$stage" in
  capture|all)
    : "${OMAGMA:?Set OMAGMA to the verified capture executable}"
    : "${OMAGMA_SHA256:?Set OMAGMA_SHA256 to its exact hash}"
    python3 video/short026/capture.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
    node video/short026/capture-images.mjs
    ;;
  film|check) ;;
  *) echo 'Usage: video/short026/build.sh [capture|film|all|check]' >&2; exit 2 ;;
esac
if [[ "$stage" == film || "$stage" == all ]]; then
  node video/short026/render.mjs
  python3 video/short026/encode.py
fi
if [[ "$stage" == check ]]; then
  node --check video/short026/cdp.mjs
  node --check video/short026/render.mjs
  node --check video/short026/capture-images.mjs
  node --check video/short026/qa.mjs
  python3 -m py_compile video/short026/capture.py video/short026/capture_picker.py video/short026/picker_fixture.py video/short026/encode.py
fi
