# Omagma v0.2.6 short film

An approximately 31-second social film showing genuine notification, local
attachment-browser, Markdown composer and light HTML-renderer output. Every
message is fictional. The captures run in owned PTYs and temporary fixture
homes; Chromium uses a fresh headless profile with external requests blocked.
Nothing here ships with the application.

The film is co-designed with actual Claude Opus 5.5 at `xhigh` effort. Its
deterministic HTML picture source is `film.html`; the collaborating engineer
captures the UI, integrates the page and verifies the resulting frames.
The first two beats use exact actual card/modal pixel crops. The fuller
picker contains ten real fictional files filtered by `Documents/ERUPTION`;
every visible filename matches the case-insensitive query. Nonmatching
controls are hidden, and the native selected `eruption-notes.md` is the same
47-byte file listed in the next attachment shot. The light HTML
hero displays the syntax-highlighted code at a readable size and retains the
real new footer. [Storyboard](STORYBOARD.md) records the final edit.

The three bullet items, short table, Python `hello()`, Zig `hello()`, one link
and inline `something` are one real saved Markdown draft. `capture.py` obtains
the exact HTML from that draft through `draft.preview`. In the browser copy,
the renderer's unique footer CID resolves to the exact approved PNG bytes.
No other mail content or renderer CSS is changed. The picture source only
composites these real screenshots with editorial titles and decoration.

The local fixture backend has fixed reserved `example.com` accounts; all
mail is synthetic and new recipients use `example.test`. No mail is sent,
including through the mock provider. The revised picker alone was captured
from a packaged Safe v0.2.6 binary; the other original captures retain their
actual v0.2.5 provenance. Per-scene capture metadata records both honestly.
On-screen version captions identify the
v0.2.6 release feature film; the source binary's actual build information and
hash are kept in the capture receipt.

Use the same ignored Slow Eruption MP3 as the earlier Omagma launch film.
The opening-alignment revision was reviewed by actual Opus 5.5/xhigh using
the user's listening feedback and the actual waveform/onset evidence, without
claiming model audio playback. It
uses the song’s own intro 0.000–4.470, then a 30ms equal-power join to source
163.266667–189.960, preserving the natural ending. Both segments are decoded
to 48 kHz and assembled by sample counts: 214560 + 1281280 − 1440 = 1494400.
The explicit
[soundtrack plan](soundtrack.json) records all cue/sample counts; picture
extensions cannot silently change the audio start. Existing song analysis
supplies the musical landmarks. Do not
replace the original launch movie or generate a new soundtrack.

All runtime stages require a live cooperative host reservation delegated by
the coordinator, as described in [verification](../../docs/VERIFICATION.md).
`HOST_TOKEN` must contain its exact ownership token. Then run:

```sh
# Regenerate picture and encode using the preserved genuine capture assets:
bash video/short026/build.sh film
# Recreate all synthetic assets from the caller's verified binary, then film:
bash video/short026/build.sh all
```

For individual stages and a visual review before the master:

```sh
python3 video/short026/capture.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
node video/short026/capture-images.mjs
node video/short026/render.mjs --stills 1.5,5.5,12.5,18.5,24.5,28.0 --out video/cache/short026/review
# To replace only the picker with a current verified binary:
python3 video/short026/capture_picker.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
node video/short026/capture-images.mjs --picker-only
# Inspect every feature and cut boundary before the full master.
node video/short026/render.mjs
python3 video/short026/encode.py
```

The output is `video/out/omagma-v0.2.6-short.mp4`: 1920×1080, 30 fps,
934 frames, H.264 High/yuv420p/BT.709, 48 kHz stereo AAC and faststart.
Matching `.report.json` records binary/song hashes, frame count, format and
measured loudness. Generated tapes, screenshots, HTML preview, audio and
frames live under ignored `video/cache/short026/`.

The revised cut is 31.133333 seconds and retains the animated five-line recap
of smaller improvements before the “Out now” ending. The completed master is
15.1 MB, measured −14.04 LUFS integrated and −4.78 dBTP;
its encoder report records the final hash, codecs and faststart/frame gates.
Mastering uses one static gain for the complete edit (+0.04 dB in this master),
preserving the composed intro swell without compression or per-segment lifts.
Original capture metadata remains app 0.2.5 / Zig 0.17.0 / safe; the version caption describes the v0.2.6
release. The previous Coming-soon master, earlier 62-second film and original
MP3 are preserved. Deliveries use `~/Videos/Omagma/`.

`cdp.mjs` follows the existing launch-film renderer's Chrome DevTools pipe
method. `capture-images.html` paints only actual captured terminal cells
through the same `TermView` used by that film. Neither file maps a desktop
window, reads a real browser profile or sends compositor input.
