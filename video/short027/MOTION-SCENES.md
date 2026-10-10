# Nine-feature motion edit

The motion revision is **81.7667 seconds / 2,453 frames at 30 fps**. The previous
72.9667-second movie and its source remain preserved. The new wrapper is
[film-motion.html](film-motion.html), with an independent output clock in
[motion.json](motion.json). The unchanged `film.html` supplies the existing
native scenes, visual design, intro, recap and ending.

Actual Claude Opus 5.5 at requested xhigh effort co-directed the concrete motion
proposal in a compact read-only consultation. Its canonical model receipt is
preserved in the ignored production cache. It approved the reveal, moderate Join
framing, full narrative and music arrangement, then recommended a longer Keep
formatting decision, an earlier persistent HTML caption, and character-count
typing progression. Those refinements are integrated. The engineer authored the
wrapper, source integration and verification code; this source is not presented
as Opus-authored. The initial long buffered consultation produced no observable
result after more than twenty minutes and was terminated/reaped before the
successful streamed retry. No model playback or audio listening is claimed.

| Chapter | Output time | Visible task |
| --- | --- | --- |
| Intro | 0.00–3.00 | Logo, version, nine highlights. |
| 01 / 09 | 3.00–8.30 | Open TUI highlight, then a gradual native inbox reveal. |
| 02 / 09 | 8.30–13.50 | Untouched action palette, genuine typed prefixes, matching actions. |
| 03 / 09 | 13.50–17.70 | Find inside the reader, then the next match. |
| 04 / 09 | 17.70–24.50 | Stage label changes, Apply, verify reader memberships. |
| 05 / 09 | 24.50–32.40 | Invitation banner, friendly review, smooth push toward `o Join`. |
| 06 / 09 | 32.40–37.00 | Choose several files, then show the attached set. |
| 07 / 09 | 37.00–54.40 | Received airline mail, keep its formatting, write a note, inspect outgoing HTML. |
| 08 / 09 | 54.40–61.60 | Send review, cancellation countdown, retained editable draft. |
| 09 / 09 | 61.60–70.43 | Genuine upgrade card and installation-specific update guide. |
| Recap | 70.43–78.20 | Existing readable minor-feature cards. |
| Ending | 78.20–81.77 | Version, website, Get Omagma, original natural music tail. |

The TUI reveal runs for 0.75 seconds on the output clock, clipping the unchanged
native inbox from left to right. The actual bar fades away under it. A separate
thin editorial edge makes the transition visible. The full inbox then has about
1.75 seconds before the next chapter. It never depicts an invented pointer click.

The Join camera pushes for 0.70 seconds, from the complete calendar review toward
its genuine controls. Its maximum scale is about 1.24× the full review view;
event, date, location and the Join control remain visible together. The same
native image supplies every camera position. A stronger crop was rejected during
visual QA because it hid the meeting context and exposed mostly empty space.

The forwarding chapter begins with its received booking rather than a blank
heading lead. Captions and native images arrive together. The same source
rectangle anchors reader and composer states. The menu, blank note and browser
transitions use short crossfades; native text changes during typing are exact
captured states rather than softened or invented glyphs.

| Forward beat | Output time | Purpose |
| --- | --- | --- |
| Received airline email | 37.00–39.20 | Establish the selected incoming booking. |
| Forward menu | 39.20–40.50 | Show its genuine native formatting choices. |
| Keep formatting | 40.50–41.60 | Highlight the actual `k` choice. |
| Blank personal note | 41.60–42.50 | Show the editable authored area before typing; signature and protected original already exist. |
| Fast typing | 42.50–45.50 | Play all twenty progressive native note/live-preview captures in proportion to genuine character counts; hold the completed state for 0.3 seconds. |
| Finished note | 45.50–47.30 | Read the complete note and its split preview. |
| Outgoing HTML | 47.30–49.50 | Show the actual native light-browser preview. |
| Connected scroll | 49.50–52.50 | Move continuously from the note toward the original airline layout. |
| Original HTML preserved | 52.50–54.40 | Show original artwork, flight table, passenger/baggage rows and booking footer. |

“Original HTML formatting preserved below your note” appears at the browser
handoff at 47.30 seconds with a 0.25-second fade and remains through the scroll
and final original view. It has about seven seconds of reading time while the
native original proves the caption. The twenty typing captures contain 18,
36, …, 342 and 358 genuine typed characters. A linear 2.7-second character clock
selects the latest captured count that has arrived; the last complete state then
holds for 0.3 seconds before the separate finished-note beat. Camera easing is
never applied to typing.

The new `forward-story` tape contains genuine fictional native cells. Its blank
state has no authored note, while the native generated signature and frozen
original remain. The 358-character note is typed through actual input; twenty
progressive captures preserve the live preview's updates. The final outgoing
HTML is copied byte for byte from the native preview artifact. Both original
embedded resources and the original HTML snapshot are independently verified.
Send review saves the completed draft for extraction; no send is confirmed.

The capture pipeline supplies `forward-story-manifest.json` in the ignored media
cache: received, menu, empty, twenty typing, final and browser asset names with
their native dimensions. Full native frames are 3520×1848, the unchanged menu
crop is 1540×528, and the native light-browser image is 2000×3800. Editorial
captions, crop/camera movement, focus outlines and chapter progress are separate
from those images. No app cells, mail text, countdown values or controls are
rewritten. Fixture-only captures use owned PTYs/homes and a new headless browser
profile with external requests blocked; termios and children are cleaned up.

[soundtrack-motion.json](soundtrack-motion.json) reuses the existing Slow Eruption
MP3, at its original tempo and pitch. It preserves the exact quiet opening
0–11.125 seconds, adds the early 8.889333–17.719333 phrase, reuses the established
8.889333–44.125 section, and ends with the original 163.294–189.960 section.
Three 30 ms equal-power seams yield exactly 3,924,800 samples at 48 kHz. The new
phrase ends before the measured 17.752-second attack; each incoming attack follows
its seam. No time stretching, silence padding or disliked middle section is used.
One static gain preserves the musical swell; measured cues are not a claim of
model audio listening.

Runtime commands require the coordinator's existing live `HOST_TOKEN` reservation:

```sh
# Fresh forwarding source from an explicitly verified v0.2.7 executable:
python3 video/short027/capture_forward_story.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
node video/short027/capture-images.mjs --tape forward-story
# Validate picture and review the moving proxy before the full master:
node video/short027/qa-motion.mjs
python3 video/short027/encode.py --plan video/short027/soundtrack-motion.json --audio-only
node video/short027/render.mjs --film film-motion.html --plan video/short027/soundtrack-motion.json --scale 0.6666666667 --step 2 --out video/cache/short027/motion-preview-frames
python3 video/short027/preview.py --frames video/cache/short027/motion-preview-frames --audio video/cache/short027/soundtrack-motion.wav --out video/cache/short027/motion-watchability-preview.mp4
node video/short027/review-motion.mjs --movie motion-watchability-preview.mp4 --interval 0.4 --ranges 'launch,5.7,8.3;join,27.5,32.4;forward,37,54.4;update,61.6,70.433' --out video/cache/short027/motion-playback-review
bash video/short027/build.sh motion
python3 video/short027/deliver.py --revision motion
```

`qa-motion.mjs` checks nine chapters, actual supplied note states, changing native
typing frames, fractional reveal/Join/scroll motion and deterministic arbitrary
seeks. The playback review uses consecutive decoded frames at 1× with wall-clock
advancement. Review the moving proxy before the full master. Source tooling never
maps a desktop window. Final copies use unique names under `~/Videos/Omagma/`;
all previous movies and pictures remain intact.

The delivered master passed the existing social-format gates: 1920×1080,
30 fps, 2,453 decoded frames, H.264 High/yuv420p, 48 kHz stereo AAC and faststart.
Measured final audio is −14.04 LUFS with −2.78 dBTP true peak. The final targeted
1× proxy pass confirms the longer formatting decision, blank note, twenty
character-count-driven native states, completed hold and persistent HTML caption.
All owned media/model children exited or were reaped, and no owned headless
browser profiles remain. Capture cleanup confirms restored termios and zero sends.
