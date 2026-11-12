# v0.2.18 — Heavy Lifting

Social film covering visible changes since the last v0.2.10 film. Actual Claude
Opus 5.5 at xhigh authors the concept, picture, motion and copy. Independent
Astra review checks clarity against the earlier films and feedback. Production
uses the published native v0.2.18 executable, controlled fictional providers,
owned PTYs and an isolated headless browser. No personal mail, desktop input,
clipboard or Google account is used.

The revised picture is 1920×1080 at 30 fps, 2,527 frames (84.233333 seconds).
Each feature announces over an empty stage, leaves 1.9 seconds to read once
the text settles, then demonstrates with fixed narration. The approved
v0.2.7 final soundtrack is reused without editing or re-encoding its AAC packets.
Music, generated captures and exported media remain in ignored cache/output
folders; previous films are preserved.

## Sources

- `film.html`, `film.css`, `film.js`, `film-plan.json`: Opus-authored film and
  exact timing, camera and review points.
- `SOCIAL.md`: accompanying release copy and smaller improvements.
- `capture.py`: unchanged application interactions, completed terminal frames,
  actual HTML preview and independent outcome receipts.
- `capture-clarity.py`: a clean live now-line view and the genuine delivered
  Sent message. Its normal provider-list read warms the fixture's cached Sent
  view; no application or message pixels are changed.
- `capture_terminal.py`, `term.js`: faithful terminal replay, retaining explicit
  SGR58 underline colour independently of meeting text colour. Blank underlined
  cells use captured cell geometry and the font's underline metrics, since
  browser text decoration omits all-space runs. `test_term.mjs` covers this.
- `capture-images.html`, `capture-images.mjs`: rasterized native frames and the
  application-generated sandboxed HTML preview. Its pasted image must actually
  decode in the child frame; the document and its CSP remain unchanged.
- `bind-assets.py`: contextual camera and spotlight rectangles derived from
  actual native cells and browser DOM positions, with unchanged-pixel aliases.
- `cdp.mjs`, `render.mjs`: isolated deterministic one-page frame rendering.
- `attention-check.mjs`: independent computed-DOM checks of every frame's
  native visibility and fixed commentary, including actual opacity and clips.
- `resource_guard.py`: host reservation verification, two-CPU Linux affinity,
  low process priority, CPU accounting, sampled aggregate RSS limit and cleanup
  restricted to identity-verified owned descendants.

## Regeneration

Inspect existing host workloads, then acquire the cooperative reservation
specified in [verification](../../docs/VERIFICATION.md#cooperative-host-measurement-lock).
Pass the coordinator's live token as `HOST_TOKEN`. Keep it until all owned
children have stopped. Use a fresh capture revision and fresh output/report
names so earlier attempts and their evidence stay available.

Capture the verified published binary into a new `revision-XX` directory:

```sh
python3 video/short0218/resource_guard.py run \
  --report video/cache/short0218/resources/capture-XX.json \
  -- python3 video/short0218/capture.py \
  --binary /path/to/verified/omagma \
  --expected-sha256 b43f4b9e2057d2112cad3e0e46a5176083aff5d4ab384f82331093b19a0c75d0 \
  --out video/cache/short0218/revision-XX
```

Rasterize and review selected moments before rendering the whole picture:

```sh
python3 video/short0218/resource_guard.py run \
  --report video/cache/short0218/resources/raster-XX.json \
  -- node video/short0218/capture-images.mjs --revision revision-XX

python3 video/short0218/bind-assets.py --revision revision-XX

python3 video/short0218/resource_guard.py run \
  --report video/cache/short0218/resources/stills-XX.json \
  -- node video/short0218/render.mjs --revision revision-XX \
     --stills 10,20,32,41,50,58 --out video/cache/short0218/stills-XX

python3 video/short0218/resource_guard.py run \
  --report video/cache/short0218/resources/render-XX.json \
  -- node video/short0218/render.mjs --revision revision-XX --workers 1 \
     --out video/cache/short0218/frames-XX
```

Use the approved AAC file at `video/cache/short0218/audio/approved-flow-84.m4a`.
It is copied from the approved v0.2.7 flow master without audio processing.
Its SHA256 is `4f849b3de93b24d841a81baa3a96177ef40deaeefeaefa07db768438c3fa854e`.
The earlier 62-second cut and launch soundtrack remain preserved. Encode:

```sh
python3 video/short0218/resource_guard.py run \
  --report video/cache/short0218/resources/encode-XX.json \
  -- python3 video/short0218/encode.py \
     --frames video/cache/short0218/frames-XX \
     --out video/out/short0218/omagma-v0.2.18-heavy-lifting-XX.mp4
```

This retains 30 fps, H.264 High, yuv420p, BT.709, exact AAC packets and
faststart, using at most two encoder threads. Record source/asset hashes,
frame count, duration and resource receipts. Review the **encoded movie at
normal speed**, as well as the meaningful stills and cut boundaries, before
copying a new uniquely named delivery into the user's Videos directory.

The guard defaults to nice15, two CPUs and a sampled 4 GiB aggregate RSS cap.
One browser page and one renderer worker are permitted. CPU affinity is a
Linux kernel constraint; RSS sampling is a watchdog, not a hard allocator limit.
Shared pages are included in aggregate RSS. Do not add work to a busy remote
host simply because a historical film used it.

## Demonstration boundaries

Drive sharing is restricted to the visible recipients and occurs during the
confirmed send. The ending shows the delivered message and its Drive link,
then folds directly into the recap. The booking example explicitly adds an
already-booked haircut as a personal calendar appointment; it is separate from
responding to a meeting invitation. The Meet option requests AI notes and transcription for a new event;
it does not demonstrate a recorded meeting or completed notes. Google
Workspace eligibility and administrator policy still apply. The current-time
marker uses the actual clock; the film shows its red line between events.
Pasted mail shows the genuine compiled fixture image and unmodified generated
HTML. Synthetic provenance is documented here rather than crowding the film.
