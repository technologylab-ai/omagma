# v0.2.19 — In Good Time

Social film covering visible changes since the user-approved v0.2.18 *Heavy
Lifting* clarity cut. Actual Claude Opus 5.5 at xhigh authors the concept,
picture, motion and copy, preserving the approved magma design: atmosphere,
strong type, glowing seams, contextual zooms and the margin ember.

The picture is 1920×1080 at 30 fps, 2,527 frames (84.233333 s). It uses the
approved AAC `video/cache/short0218/audio/approved-flow-84.m4a` without edits
(SHA256 `4f849b3d…3fa854e`). There are five stories:

1. Calendar Day/Week grid and Orange & Blue look (Ctrl+T Classic and back)
2. Guest suggestions
3. RSVP with review
4. A personal bill reminder from an emailed .ics
5. Discarding a draft and restoring it with Ctrl+Z

Each story announces over an empty stage and leaves 1.9 s to read once the
text settles. It then demonstrates with fixed narration and ends on a populated
result. The restored draft lands on the closing-phrase attack. A short recap
precedes the unchanged outro timing.

## Sources

- `film.html`, `film.css`, `film.js`, `film-plan.json`: the Opus-authored film
  with its exact timing, cameras, spotlights and review points. `film.js`
  validates its own clock and rejects plan drift, missing assets and mixed
  capture grids within a shot.
- `CAPTURE-CONTRACT.md`: the genuine states, real actions, fixtures, camera and
  spotlight bindings, legibility limits and receipts that capture engineering
  must deliver.
- `SOCIAL.md`: release post, smaller improvements and copy decisions.

Capture, raster, binding, render, attention-check and encode tools are adapted
from `video/short0218/` by root, following the contract's tooling section.
Paths move to `short0219`; the frame count stays 2527. Inputs are read from
`video/cache/short0219/revision-XX/`. Render with
`film.html?revision=revision-XX`.

## Demonstration boundaries

All accounts, people and senders are fictional, on reserved domains. The now
line uses the actual clock. Guest suggestions come from local cached data:
nothing is selected automatically and typing sends nothing. RSVP changes
Calendar only after `y`. The .ics import adds an attendee-free personal event
and is not a meeting invitation. Draft restore covers the last discarded draft
per account for up to seven days and does not touch Gmail. Generated captures
and media stay in ignored cache/output folders, and earlier films are
preserved.
