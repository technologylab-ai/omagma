# Continuous nine-feature edit

The preferred audio is the later continuation edit in
[soundtrack-continuation.json](soundtrack-continuation.json): source 0–70.000
seconds and 174.000–189.960 seconds, overlapping at film 68.040–70.000.
The original music around 53 seconds now continues for another fifteen seconds
before any edit. The final drum fill prepares the softer closing phrase; the
original stop and decay still finish at 84 seconds. Tempo and pitch are unchanged.
The older 52.600-second handoff described below remains a comparison arrangement;
the user's listening feedback found that it interrupted a passage they enjoyed.

This revision replaces only the soundtrack. The approved video packets, frame
count, timing and color metadata are preserved by [replace_audio.py](replace_audio.py).
Signal checks establish source continuity, not subjective musical approval.

```sh
python3 video/short027/encode.py --plan video/short027/soundtrack-continuation.json --audio-only
python3 video/short027/replace_audio.py --video "$REVIEWED_VIDEO" --expected-video-sha256 "$REVIEWED_VIDEO_SHA256" --audio video/cache/short027/soundtrack-continuation.wav --plan video/short027/soundtrack-continuation.json --out video/out/omagma-v0.2.7-continuation.mp4
python3 video/short027/deliver.py --revision continuation
```

These commands use the same existing live host reservation. They create a new
movie and preserve previous delivered versions; the picture is not rendered again.

The current source runs **84.000 seconds / 2,520 frames at 30 fps**. It rebuilds
every native UI handoff around one steady background, while retaining the gradual
TUI reveal, purposeful camera moves, complete forwarding story, update guide and
all nine features. [film-smooth.html](film-smooth.html) is a direct compositor;
[smooth.json](smooth.json) supplies its output-clock phases. It does not remap or
inherit the older film's screenshot visibility, dimming or camera clocks.

The previous 81.767-second motion comparison remains preserved. Its palette
closed before Find arrived, exposing a bright inbox and then a title-only gap.
Global music-cue flashes changed the entire frame's brightness, including during
label staging. Its short early music repeat also introduced a splice near twenty
seconds. The earlier sparse review missed those brief intermediate states.

The new compositor keeps the intended outgoing view opaque under the incoming
view's short fade. Both scenes paint the same background; an unrelated inbox or
empty UI is never inserted between them. Native typing, checkbox changes and
focus states replace genuine captured images in the same viewport. Changed
bitmaps are explicitly decoded before a renderer captures its frame. A separate
caption layer changes headings without overlapping two titles, while the picture
continues underneath. No global flash or pulsing brightness remains.

| Chapter | Output time | Visible task |
| --- | --- | --- |
| Intro | 0.00–3.20 | Logo, version and nine highlights. |
| 01 / 09 | 3.20–8.60 | Open TUI, then a 0.75-second gradual native inbox reveal. |
| 02 / 09 | 8.60–13.90 | Untouched palette, native typed prefixes, matching actions. |
| 03 / 09 | 13.90–18.30 | Direct palette-to-Find handoff, first match, next match. |
| 04 / 09 | 18.30–27.00 | Stage labels, explicit Apply, verified result and a gentle reader push. |
| 05 / 09 | 27.00–34.30 | Invitation, friendly review, moderate push toward `o Join`. |
| 06 / 09 | 34.30–39.00 | Choose three files, show the composer, then focus its attached set. |
| 07 / 09 | 39.00–57.50 | Received airline mail, formatting choice, blank note, native typing, outgoing HTML and original booking. |
| 08 / 09 | 57.50–64.40 | Send review, cancellation countdown, retained editable draft. |
| 09 / 09 | 64.40–72.50 | Genuine update card, How action and installation-specific guide. |
| Recap | 72.50–80.30 | Existing readable minor-feature cards. |
| Ending | 80.30–84.00 | Version, website, Get Omagma and the original musical tail. |

Camera movement begins after the UI handoff. The labels push is gentler than the
initial proposal; the meeting ring moves from applied labels to the invitation.
Join keeps event, date, location and the actual control in view. Attachments enter
as a complete composer before the camera approaches the genuine file list;
the three file indices and names remain legible. Dark-to-white and white-to-dark
browser handoffs receive 0.7 seconds. The browser scroll stays connected from
the personal note to the original airline artwork, flight table and booking footer.

The forwarding images remain unmodified genuine synthetic captures. The authored
note starts blank above the generated signature and protected original. Twenty
native states show the 358-character Markdown note and live preview growing
together; their progression uses actual captured character counts. The complete
state receives a short hold before the separate finished-note beat. The outgoing
browser HTML is the native preview artifact copied byte for byte, with both
original CID resources preserved. No send is confirmed and no real mailbox,
desktop input or existing browser profile is used.

[soundtrack-smooth.json](soundtrack-smooth.json) uses the same Slow Eruption MP3
at its original tempo and pitch. The original 0–53.400-second opening plays
continuously, so no early repeat or splice occurs during staged labels. One
800 ms equal-power overlap at film 52.600–53.400 seconds joins source
158.560–189.960 seconds, preserving the composed ending and natural decay.
The disliked middle is skipped. Exact 48 kHz sample cues yield 4,032,000 samples;
there is no stretching, pitch processing, silence padding or per-segment gain.

Actual Claude Opus 5.5 at requested xhigh effort visually co-reviewed the old
movie's real decoded boundary frames and the new compositor proposal. The evidence
contains every old phase boundary at consecutive 30 fps, plus extended palette,
labels and music-cue windows. The primary request exceeded the model's retained
image limit: 31 strips remained available, and the model reported that limitation.
A separate bounded pass confirmed all 18 missing early strips as actual images.
Together the two completed passes cover 49 unique dense decoded strips. Their
canonical model results, source snapshot hashes and coverage caveats are preserved
in the ignored `opus-smooth` production cache.

The model confirmed the old inbox flash, broad cue flashes, empty/title-only
intermediates and abrupt camera/shape changes. Its actionable source review
reinforced gentler label movement, separate caption chrome, longer white/dark
handoffs and explicit bitmap preparation. The bitmap preparation was already
implemented before the review result arrived. The engineer authored the implementation and
integration. This is not a claim that the model played the movie, heard its audio
or visually accepted the final encoded master.

Regeneration requires the coordinator's existing live `HOST_TOKEN` reservation
and verified genuine capture assets:

```sh
# Refresh the received/menu/blank/typing/final/native-browser sequence:
python3 video/short027/capture_forward_story.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
node video/short027/capture-images.mjs --tape forward-story
# Prepare and check the direct compositor, then build a master:
node video/short027/qa-smooth.mjs
bash video/short027/build.sh smooth
# Copy the exact master into owned cache and review the whole film at 1×:
cp video/out/omagma-v0.2.7-smooth.mp4 video/cache/short027/smooth-final-master-review.mp4
node video/short027/review-motion.mjs --movie smooth-final-master-review.mp4 --ranges 'full,0,83.8' --interval .2 --out video/cache/short027/smooth-playback-review/final-master
# Inspect dense decoded handoffs before making a unique final copy:
python3 video/short027/deliver.py --revision smooth
```

The review standard covers the whole moving movie. Source QA checks every
semantic output frame and prepared pixels across independent renderers at all
handoffs, allowing only tightly bounded invisible edge-rounding noise. These
checks support, rather than replace, dense decoded 30 fps review of every chapter,
native substate and caption handoff plus full 1× playback with verified clock
advancement. Inspect the encoded background, intended UI states, camera movement,
attachment names/indices, typing and white/dark browser handoffs. Metadata alone
is not visual acceptance. Genuine native swaps may change their expected cells;
full-frame flashes, throwaway views or lost action/file content are blockers.

The master path is `video/out/omagma-v0.2.7-smooth.mp4`. Deliveries use exclusive,
unique filenames under `~/Videos/Omagma/`; all prior delivered movies remain.
