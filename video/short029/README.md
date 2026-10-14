# Omagma v0.2.9 · What’s new

Six native workflows: local encryption and the unlocked daemon, Calendar,
profile-aware meeting Join, RSVP with Calendar saving, local follow-ups,
and continuing a draft in Gmail. The ending recaps smaller mail improvements.

The film uses the established deterministic HTML compositor: 1920×1080,
30 fps, exactly 2,527 frames (84.233333 seconds). It copies the approved
v0.2.7-flow soundtrack unchanged, including every encoded packet and timestamp.
The MP3 is never sped up, re-spliced, normalized or faded.

All application footage comes from the frozen v0.2.9 binary, fictional fixtures
and owned PTYs. The animated lock/password/daemon diagram explains the flow;
it is an editorial visualization, separate from the real native captures.
Calendar and Follow-ups enter through highlighted native sidebar items.
The populated Week leads into Join on that same event before Mail invitations.
The Mail invitation card and searchable Calendar help are actual app changes.
`capture_vault.py` actually initializes and unlocks an encrypted
fixture vault, reads it through a separate CLI process and opens the native TUI
against the same service. Passwords and recovery material are never saved in
the captures. Native activation is exercised in a private synthetic HOME.

`capture_calendar.py` proves one synthetic RSVP send and one Calendar update,
a local reminder, and an explicit Gmail draft upload that pauses local edits.
Meeting Join displays the actual profile-routing result. A separate synthetic
Chrome executable records and verifies the exact account, profile and URL;
the film does not invent a meeting website. No production account is accessed.
`capture_join_compact.py` repeats the Join scene in a smaller native terminal,
keeping the event, camera button and selected browser profile visible together.

The video terminal renderer paints cell backgrounds before foreground glyphs,
matching terminal behavior and preserving Nerd Font camera-glyph overhangs.
Capture rasters are otherwise unchanged native cells. `measure-rois.mjs` finds
clean pane, action and result bounds directly in those same terminal tapes.

Use one live shared-host reservation for the heavy stages, serially:

```sh
HOST_TOKEN=… python3 video/short029/capture_calendar.py --help
HOST_TOKEN=… python3 video/short029/capture_vault.py --binary /path/to/frozen/omagma --out video/cache/short029/revision-02/vault
HOST_TOKEN=… node video/short029/capture-images.mjs
python3 video/short029/refine.py
HOST_TOKEN=… node video/short029/render.mjs --stills 0,8,16,24,32,40,48,56,64,72,80 --out video/cache/short029/stills
HOST_TOKEN=… node video/short029/render.mjs --out video/cache/short029/frames
HOST_TOKEN=… python3 video/short029/encode.py --frames video/cache/short029/frames --out video/out/omagma-v0.2.9-whats-new.mp4
```

Review composed stills before full encoding. Then inspect consecutive frames at
every phase handoff and play the actual encoded movie at 1× using `review.mjs`.
Its muted playback checks decoded pictures and timing; exact approved-audio
comparison is separate and does not constitute a new listening claim.
`deliver.py` verifies source hashes and playback receipts before writing a new
dated MP4, poster, local player, contact sheet and report to `~/Videos/Omagma/`.
Earlier videos are preserved. The application release remains a separate step.

Opus 5.5 xhigh directed the cut and reviewed composed pictures. Astra reviewed
the product claims and action/result continuity. The final refinements enlarge
the agenda, spotlight Join and confirmed RSVP outcomes, keep the genuine Accept
focus frame, and show Follow-ups entry only after saving the reminder. `refine.py` applies these decisions
after rasterization without altering any captured application text.

## Directed revision 03

`direction.js` and `direction.css` provide the separate editorial motion layer.
The new storyboard replaces the rejected revision02 chapter bridges and orange
outline treatment. Preserve the source manifest, original audio, and native assets;
render into a fresh revision cache directory. See `STORYBOARD.md` for the clock.

## Context revision 04

`capture_week_compact.py` and `capture_week_compact.mjs` replace only Week with
a genuine 132×28 native capture using the same frozen binary and fictional
meetings. The smaller terminal shows daytime hours with larger text. Sidebar
crops retain neighboring mail, Contacts, Calendar and labels; the saved reminder
and Follow-ups list share framing that keeps the navigation visible. The clock,
headings, other sequences and soundtrack stay unchanged.

Revision05 names the new background daemon in the first feature headline, with
shared TUI/agent unlocking explained directly below. All timing stays unchanged.

## Meeting notifications revision 06

The calendar/Join sequence now shows a genuine notification arriving over Mail,
its minutes-before and minutes-remaining states, deliberate action focus, and
profile-aware Join. `capture_notifications.py` uses the native fixture-only clock;
`capture_notifications.mjs` rasterizes those completed PTY states and preserves
all earlier assets. The two clock states are separated by an explicit time-jump
caption. Two seconds move from recap into this sequence; the film duration and
approved audio packets remain unchanged. The manifest records the new candidate
binary separately from the approved earlier native workflows.

Revision07 replaces the function-key focus requirement with **M** for meeting
actions. New native captures show the updated hint and controls, and the film's
key cue matches. The sequence timing and soundtrack remain unchanged.
