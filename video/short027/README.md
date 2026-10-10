# Current continuous nine-feature edit

The preferred soundtrack is now [soundtrack-aligned.json](soundtrack-aligned.json).
The original passage and complete fill play through 70.446 seconds. A short
pre-attack join then admits one closing-phrase drum entrance; two active drum
patterns are not overlapped. Music determines the 84.233-second duration:
seven frames extend only the final website still, and all UI sequences keep
their approved timing. Earlier soundtrack edits remain for comparison.

The current source is an **84.000-second, nine-highlight continuous edit**.
Every native UI transition now uses an explicit output clock and one steady
background. Palette hands directly to Find; chapter changes retain their picture;
headings change separately; global brightness flashes and the early music loop
are removed. The gradual TUI reveal, focused camera moves, complete genuine
forwarding story and ninth update-guide scene remain.
[Transition policy, actual visual co-review and reproduction](SMOOTH-EDIT.md)
describe the edit. All previous sources and delivered comparison movies remain
preserved, including the 81.767-second motion and 72.967-second nine-feature edits.

With the coordinator's existing live `HOST_TOKEN` reservation and genuine source
assets already captured, build the base picture:

```sh
node video/short027/qa-smooth.mjs
bash video/short027/build.sh smooth
python3 video/short027/deliver.py --revision smooth
```

That block preserves the earlier comparison soundtrack. For the preferred
aligned soundtrack, use the frame-fit commands at the top of
[SMOOTH-EDIT.md](SMOOTH-EDIT.md) and deliver with `--revision aligned`.
The approved rendered frames are reused, avoiding a UI picture rerender.

Review the actual encoded master at 1× and inspect dense consecutive 30 fps
handoff frames before delivery. Current output is
`video/out/omagma-v0.2.7-smooth.mp4`; unique final copies belong in
`~/Videos/Omagma/`. [SMOOTH-EDIT.md](SMOOTH-EDIT.md) includes fresh forward capture
and explains the full transition-review standard. The older
[MOTION-SCENES.md](MOTION-SCENES.md) records the preserved motion comparison.

## Earlier eight-feature edits

The previous polished eight-feature edit is the **64.133-second polished edit**. It budgets the whole
visible UI state, including fades and camera motion, rather than only its
settled tail. The invitation banner receives 2.1 seconds and its full review
layout stays stationary through Join. Send review/countdown each receive two
seconds, with an earlier Undo cue and 2.3 seconds on the retained draft. Old screenshots fade away during the next chapter introduction,
so a label or Find result does not linger behind the following heading. Simple
states generally last 1.1–2.0 seconds; the denser meeting/browser views retain
slightly more time. The recap uses concrete action wording and music remains
at its original tempo and pitch.

```sh
bash video/short027/build.sh brisk
python3 video/short027/deliver.py --revision polished
```

[brisk.json](brisk.json) controls complete state durations.
[film-brisk.html](film-brisk.html) applies those timings to the genuine source
picture and separates its decorative accents from the normal-tempo music clock.
[soundtrack-brisk.json](soundtrack-brisk.json) reuses the established original
song edit. Older exports remain available for comparison.

The longer comparison film is the calmer revision: **105.967 seconds, 3,179 frames at 30 fps,
1920×1080**. It preserves the orange/magma design while showing one complete
task per chapter. Headings and context arrive together before the UI action;
settled native states remain on screen long enough to read. Help, saved-search,
color and recipient-picker popups are described in the recap rather than
interrupting the main workflows.

A further comparison edit runs **97.133 seconds**. It trims idle scene endings
to about two seconds while retaining the original camera and transition speeds.
The action palette now opens unfiltered, then real captured keystrokes narrow
the choices through `l`, `la`, `lab`, `labe`, and `label`. Its title and filter
row stay in the same place. Music plays at its original tempo and pitch; a
shorter arrangement of the same opening, early phrases and natural ending fits
the picture. The recap keeps its reading time.

Generate the shorter edit from the current full-resolution frame set:

```sh
python3 video/short027/trim_holds.py
```

When reusing the earlier frame set, render only the new palette sequence first:

```sh
node video/short027/render.mjs --from 14.9 --to 21.7 --out video/cache/short027/palette-sequence-frames
python3 video/short027/trim_holds.py --palette-frames video/cache/short027/palette-sequence-frames
```

[holds-2s.json](holds-2s.json) records the frame cuts and original-tempo music
sample ranges. Earlier delivered movies remain available for comparison.

Actual Claude Opus 5.5 at xhigh effort revised the picture source in an isolated
public-only workspace. The engineer integrated genuine synthetic captures,
checked the actual timeline and consecutive frames, and retained composer
context around Undo Send. [Production notes](PRODUCTION-NOTES.md) and
[storyboard](STORYBOARD.md) record the final edit.
[Feature coverage](FEATURE-COVERAGE.md) maps the complete release feature set;
[SOCIAL.md](SOCIAL.md) provides concise post copy.

Every application region is an unmodified real capture with invented accounts,
people and mail. The label demonstration now performs the real workflow:
initial membership → stage remove/add → explicit Apply → verified result on
both pinned messages. The resulting reader leads into its own invitation
review. No real mailbox, browser profile, desktop input or mail send is used.

The original 61.9-second delivered movie is preserved. Its picture/cue source is
archived under versions/. The current soundtrack uses the same Slow Eruption
MP3: its original opening from 0–44.125 seconds, one repeat of positive early phrases
from 8.889333–44.125 seconds, and its natural ending from 163.294–189.960 seconds, joined with 30 ms
equal-power seams. Exact 48 kHz sample cues in [soundtrack.json](soundtrack.json)
give 3,179 frames. No pitch/tempo changes, silence padding or disliked middle
section is introduced. Music accents never force an unreadable UI switch.

All runtime stages need the coordinator's live cooperative host reservation.
HOST_TOKEN contains that reservation's token. Source tooling never maps a
desktop window; owned Chromium profiles run headless with external requests
blocked.

~~~sh
# Preserve/regenerate genuine source assets from an explicitly verified binary:
bash video/short027/build.sh capture
# This includes capture_labels.py; default rasterization includes the focused labels take.
# Current full-resolution calmer master:
bash video/short027/build.sh film
# Copy verified master/poster/contact sheet into unique Videos filenames:
python3 video/short027/deliver.py
# Real-time motion proxy, followed by consecutive decoded playback frames:
python3 video/short027/encode.py --audio-only
node video/short027/render.mjs --scale 0.6666666667 --step 2 --out video/cache/short027/calm-preview-frames
python3 video/short027/preview.py
node video/short027/review-motion.mjs
# Focused frame/source verification:
node video/short027/render.mjs --stills 17.4,24.8,32.7,37.5,41.8,49,58.2,74.8,81,87.5,91,98 --out video/cache/short027/calm-review
node video/short027/qa.mjs
bash video/short027/build.sh check
~~~

Current frames live in ignored video/cache/short027/calm-frames. The master is
video/out/omagma-v0.2.7-whats-new-calmer.mp4. Deliveries use unique filenames
under ~/Videos/Omagma/ with a calmer suffix. The renderer records its complete
phase table, settled holds and contextual step cues; playback review verifies
1× clock advancement and captures consecutive decoded frames. These checks
support practical watchability review rather than only one still per chapter.

The eight counted highlights are bar launch, searchable actions, in-message
Find, staged labels, meeting Join, multiple attachments, preserved original
formatting and cancellable sending. Further improvements are grouped in the
two-card recap. The ending says What's new in v0.2.7 and Get Omagma; publication
is not asserted. TUI/CLI remain experimental. The bar is Omarchy/Linux, while
the terminal client also supports macOS.
