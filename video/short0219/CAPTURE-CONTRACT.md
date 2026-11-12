# v0.2.19 film — capture asset contract

Handoff from film direction (actual Claude Opus 5.5 xhigh) to capture
engineering. The film (`film.js`, `film-plan.json`) consumes exactly the
assets below. Every pixel inside a frame is a genuine completed native frame of
the **published v0.2.19 executable**. No HTML re-implementation, no retouching,
no clock or outcome fabrication. Where this document quotes UI wording, it gives
intent only. Bind the actual rendered strings and record them in the binding
receipt.

## Ground rules

- **Fictional data only.** Accounts, people, senders and domains use reserved
  names: `example.com/.net/.org`, `.test`, `.example`, `.invalid`. No personal
  mail, clipboard, desktop input or production Google account.
- **Actual clock.** Whenever the now line can appear, the OS clock is real.
  Seed events relative to the capture time. If the current time falls outside
  the framed working hours, wait and capture later. Never fake the clock.
- **Look.** Fresh isolated config with `theme: "omagma"` and
  `calendarLook: "orange_blue"`. Only `calendar.day-classic` shows Classic.
- **Same grid per story.** Assets in the same shot come from one PTY session
  with fixed columns/rows. That lets normalized camera rectangles glide between
  states. The `ics.calendar` shot is separate, so it may use its own session.
- **Atomic states.** Each asset is one completed frame (`tape` + `frame`). The
  film swaps whole images on the key-press frame. It never blends two states.
- **Real actions.** Every state is reached from the previous one by the
  listed real keys, after any wait the application requires. Record keys and
  timestamps in the tape marks.
- **No fallback.** Required assets that are missing or invalid fail `READY` and
  report a clear reason. Do not substitute empty or older screens.

## Manifest (unchanged schema)

`video/cache/short0219/revision-XX/assets-manifest.json`,
`schema: omagma.video.assets.v1`. Each asset entry has `file`, `width`,
`height`, `sha256`, `tape`, `tapeSha256`, `frame`, `columns`, `rows` and
`provenance`. It also has these rectangles, all normalized `[x, y, w, h]`:

- `cameraRois.<name>`: contextual framing.
- `rois.<name>`: tighter spotlight, covering meaningful characters only.
  Trailing blank cells are excluded, and the rectangle must lie inside that
  asset's camera.

`film-plan.json → assetRequirements.namedRois` lists every name the film
reads. `film.js` reports any missing name as `roi-fallback`. `qa(t)` raises a
warning whenever that asset is visible, so the attention check fails. Asset IDs
use the existing rule `^[a-z0-9][a-z0-9.-]*$`. The same applies to
`capture-images.mjs` and `bind-assets.py`.

## Legibility arithmetic

These limits assume the v0.2.18 raster at DPR2, where 1 cell = 22×44 image px
and the advance is 0.6 em. The frame interior is 1652×732 CSS px, or 1652×716
in the draft beat's `foot` box. Native size = `36.67 × k`. Here k is the
smallest of `75.1/cols`, `16.6/rows` (`16.3/rows` for the draft beat), `1.0`,
and a 34 px cap.

| apparent native text | max camera cells (cols × rows) |
| --- | --- |
| 30 px (target) | 91 × 20 (draft: 91 × 19.5) |
| 28 px | 98 × 21.8 |
| 26 px (floor, overview only) | 105 × 23.5 |
| > 34 px is capped | smaller crops are centered with more atmosphere around them |

Keep pane borders when they explain *where* the action happens. If a different
raster cell size is used, scale these limits accordingly and report it.

## Story 1: Calendar grid and look (shot `grid-native`, 7.20–19.83 s)

Session: **104×30** (as engineered). The full 104-column Week fits at 26.5 px,
the review floor. Capture on a weekday when possible, so today has neighbours
on both sides.

Product constraint (current source, `min_lane_cells = 8`): a Week day column
of about 14 cells cannot split two lanes. In Week, the overlapping pair is
therefore drawn as one block with the genuine `+1` overflow (e.g.
`Design cri+1`). Side-by-side lanes are demonstrated **only in Day**, after
the real `2` press. Do not capture a wider Week (two Week lanes need about 126
columns, which falls below 26 px) and do not alter pixels.

Seed data (personal fictional calendar, colours from saved identities):

- Today, all-day: **Recycling day**.
- Today, earlier: **Standup** ending at least one grid row above the now line.
- Today, later: **Design crit** and **Vendor call**. Their times overlap, and
  both start at least one row below now. They draw side by side in Day, and as
  `+1` overflow in Week.
- The now row in today's column stays **blank** between the earlier and later
  events, so the genuine indicator is clearly visible.
- Neighbouring days: 3–5 short titles, ≤12 characters, e.g. **Gym**,
  **Lunch w/ Sam**, **Dentist**, **1:1 Priya**, plus one all-day item.

| asset | real action | camera (`cameraRois`) | spotlight (`rois`) |
| --- | --- | --- | --- |
| `calendar.week` | `C`, `3` Week, Orange & Blue | `week`: all 104 cols × ≤23 rows. Covers day headers, all-day band, Standup, the now indicator and the later block. `today`: ≤84×19, from the time gutter (incl. the actual `HH:MM` now label) through today's column + 1 neighbour. | `column`: today's column from Standup through the later block, incl. its genuine `+1` and the blank now row between. Meaningful cells only, inside `today`. |
| `calendar.day` | `2` | `day`: all 104 cols × exactly **23 rows**, starting at the Day tab/header row. That gives 26.5 px and fills the 760 px frame box. Covers Day header, all-day band, Standup, now indicator and **both lane blocks entirely** through their last row (Design crit to 16:30). `calendar.day`, `-classic` and `-back` use identical cells. | `lanes`: both genuinely split side-by-side lane blocks with their titles |
| `calendar.day-classic` | `Ctrl+T` | `day`: **identical cells** to `calendar.day` | (none) |
| `calendar.day-back` | `Ctrl+T` again | `day`: identical cells | `allday`: the Recycling day band text |

Receipts: provider calls do not change across both toggles. There are zero
writes and zero sends. `ui.json` changes `orange_blue → classic_pastel →
orange_blue`.

Now-indicator proof (the current v0.2.19 indicator, not v0.2.18's SGR
underline and `now` word):

- Record capture UTC and local time.
- Record the now-row index.
- Record the genuine red horizontal `─` cells on that row across today's
  column.
- Record the actual `HH:MM` gutter label and check it against the recorded
  local clock within one tick.
- Confirm the absence of event glyphs on that row between the earlier and later
  events.
- In Day, confirm both lanes occupy distinct column ranges, each at least 8
  cells wide.

The raster must visibly show the red `─` line. Check the pixels, not just the
attributes.

## Story 2: Guest suggestions (shot `guests-native`, 22.87–33.17 s)

Session: about 96×26. In Calendar, `n` opens a new event with title
**Planning lunch** on the personal primary calendar, and Guests is focused and
empty. The current account's cached recent mail contains
**Alex Example \<alex@example.test\>**. One other `al…` match is allowed, but
Alex must be listed first. Warm the cache with normal provider-list reads only.

| asset | real action | camera | spotlight |
| --- | --- | --- | --- |
| `guest.empty` | focus Guests | `form`: **identical cells for all five assets**, ≤96×21. Runs from the form's Title row through the bottom of the suggestion popup, measured in `guest.suggest`, plus 1 row, at full popup width. | `guests`: Guests row incl. its Browse all hint |
| `guest.typed` *(optional)* | type `a` | `form` | (none). Proves nothing appears after one letter. |
| `guest.suggest` | type `l` | `form` | `suggest`: popup header through the Alex row. **Nothing selected.** |
| `guest.selected` | `Down` (or `Ctrl+N`) | `form` | `choice`: the highlighted Alex row |
| `guest.added` | `Enter` | `form` | `field`: Guests row showing the entered address |

Receipts: provider call count is unchanged while typing (local suggestions
only). There are zero sends and zero Calendar writes. The Guests value contains
`alex@example.test` without the unfinished `al`.

## Story 3: RSVP (shot `rsvp-native`, 36.20–45.67 s)

Session: about 96×22, Day view, so the whole screen including the status row
fits ≤98×21.8. Invitation **Studio sync** later today (or the Day being shown).
The organizer is **Jordan Example \<jordan@example.org\>** and your fictional
account is invited with no answer yet. Surround it with 2+ other events so the
grid stays populated.

| asset | real action | camera | spotlight |
| --- | --- | --- | --- |
| `rsvp.before` | select Studio sync | `result`: Day header through the status row, including the invitation | `event`: Studio sync block with its unanswered mark |
| `rsvp.review` | `r` | `dialog`: **exactly the dialog's outer border box** (border cells included). No surrounding calendar context and no partial background words such as a cut "Today" or hour digits. The 34 px cap sets the size. | `choices`: Accept / Maybe / Decline |
| `rsvp.accept` | `a` | `dialog`: **this state's own exact outer border box** (measured [9,4,78,14]). That is one row taller than review's [9,4,78,13], because the wrapped consequence adds a row. These are not identical cells, so the film cuts the camera atomically here (`camDur 0`). | `confirm`: the consequence sentence and the confirm button |
| `rsvp.done` | `y`, after the dialog has been shown unchanged ≥0.6 s, as the app requires | `result`: identical cells to `rsvp.before` | `status` only: the genuine "Accepted · Studio sync · …" status text, meaningful characters. Spotlit 1304–1366; no `event` spot. |

Receipts: before `y` there are zero writes. After `y`, exactly one
version-checked patch sets this account's attendee to `accepted`. There are no
deletes. The event remains in the view.

## Story 4: Personal reminder from an emailed .ics (48.70–59.67 s)

Mail message from **Harbor Utilities \<billing@harbor-utilities.example\>**:

- Subject: **Your November bill**
- Body: a short line like "€48.20 is due on <due date>. A calendar reminder
  is attached."
- Attachment: `payment-due.ics`. It is published (no METHOD or
  `METHOD:PUBLISH`) and attendee-free, with an all-day
  `DTSTART;VALUE=DATE` of the due date and SUMMARY
  **Pay Harbor Utilities bill**.
- One `VALARM ACTION:DISPLAY` with an elapsed trigger, e.g. `-PT15H` (09:00
  the day before). Nominal `-P1D` is unsupported.
- Due date 2–5 days after capture, inside the displayed week if possible.

This is explicitly a personal bill reminder. It is not a meeting invitation,
and it is not a repeat of the v0.2.18 haircut booking.

Shot `ics-mail`. Session about 100×28:

| asset | real action | camera | spotlight |
| --- | --- | --- | --- |
| `ics.mail` | open the message | `reader`: ≤92×20. Covers From, Subject, body line, attachment and its calendar hint/card. | `card`: the attachment/calendar card with its A hint |
| `ics.review` | `A` | `modal`: **exactly the confirmation card's outer border box** (border cells included). No background mail list, no partial "Labels". `ics.saved` uses identical cells. | `details`: title through Reminder line, as wide as the **widest line it spans**, including the full Calendar account line ("Calendar  Primary · personal@example.com") |
| `ics.saved` | `y` | `modal`: identical cells | `status`: the genuine Added result line |

Shot `ics-calendar`. It opens on a hard cut, so the navigation keys are not
shown. Record them, e.g. `q` then `C` and `2`, plus any date moves:

| asset | real action | camera | spotlight |
| --- | --- | --- | --- |
| `ics.calendar` | Day view of the due date | `day`: full width × ≤21 rows. Covers the all-day band containing **Pay Harbor Utilities bill** plus ≥2 other timed events that day. **Must be populated.** | `added`: the new all-day item |

Receipts: exactly one Calendar insert into the receiving account's primary
calendar. It has no attendees, the all-day date matches the file, and the popup
reminder matches. There are zero sends. If the due date is not today, the now
line is legitimately absent.

## Story 5: Discard draft and undo (shot `draft-native`, 62.70–73.00 s)

Session: about 96×24. Compose a new message from the personal account:

- To: **Maya Example \<maya@example.org\>**
- Subject: **Saturday plans**
- Body (typed for real, 3–4 visible lines):
  "Hi Maya, / Shall we try the new bakery on Saturday? / I can book a table
  for ten. / Robin"

The Inbox behind it holds ≥5 fictional messages, so the discarded state is not
empty.

**Allowed pre-story setup.** This happens before `draft.typing` and is not
shown in the film:

1. Ctrl+S opens an ordinary send review.
2. Esc returns to the composer without sending.
3. `i` resumes editing.

This validates the composer's local fields (`recoveryFields = false`), so the
typing and restored states both show native MIME size (0.1 / 35 MiB) with no
error. Record every setup key in the tape marks. The proof must show:

- zero sends;
- the restored body exactly equal to the typed body;
- no key press between `Ctrl+Z` and the end of `draft.restored`.

| asset | real action | camera | spotlight |
| --- | --- | --- | --- |
| `draft.typing` | typed body, cursor at end | `compose`: **identical cells to `draft.restored`**. All 96 cols × ≤20 rows, giving 28.7 px. Starts at row 1, **below row 0**, the app header that names the fixture provider. Runs through the composer's Attachments row. **Excludes the footer/status rows.** Covers both pane borders, To, Subject and all body lines. | `body`: the body lines' meaningful characters |
| `draft.review` | `Ctrl+X` | `review`: all 96 cols × ≤20 rows, below row 0. Covers the discard review with its composer context. | `prompt`: the review question and its controls as rendered |
| `draft.discarded` | `Ctrl+X` again, after the review's required visible time | `mail`: all 96 cols × 21 rows, starting at row 3 (`[0,3,96,21]`), as approved in Opus's composed visual closure. This mail-only exception includes the first subject, ≥5 complete list rows and the genuine status naming the undo. No mid-word cut in the reader pane. | `status`: that status text |
| `draft.restored` | `Ctrl+Z` | `compose`: identical cells. The film **cuts** the camera atomically here (no glide), so the genuine recovery footer "Message size unavailable: UnfinishedDraft" is never crossed. It must lie outside `compose`. Do not retouch it or add a hidden key press to clear it. | `body`: the same lines |

Receipts: zero sends. No Gmail draft is deleted. The restored body text cells
are **cell-for-cell equal** to `draft.typing` within `rois.body`; a cursor
difference is allowed. Record the composer's local kept-draft state transitions.

## Film-side timing (fixed, for reference)

Frames are at 30 fps. Each asset is shown from the listed frame until the next
one. The capture only needs one completed frame per state. The film's hold
times are editorial.

| story | states (frame) |
| --- | --- |
| Calendar | week 216 · today push 272–296 · day 352 · day-classic 446 · day-back 510 → 595 |
| Guests | empty 686 · typed 746 · suggest 754 · selected 838 · added 900 → 995 |
| RSVP | before 1086 · review 1156 · accept 1220 (atomic camera cut) · done 1286 → 1370 |
| ICS | mail 1461 · review 1528 · saved 1610 · calendar 1680 (cut) → 1790 |
| Draft | typing 1881 · review 1960 · discarded 2034 · restored 2114 (closing-phrase attack; atomic camera cut) → 2190 |

Spotlights in every story are padded 10 px horizontally and 3 px vertically.
Bind `rois` tightly to whole rows of meaningful characters, so the wash edge
lands in the inter-row gap.

## Tooling adaptation (root)

Copy the v0.2.18 production tools into `video/short0219/` and keep their
safeguards. Apply these changes:

- Paths `short0218 → short0219`.
- Default revision `revision-01`.
- `FRAMES` unchanged at 2527.
- Same approved AAC (`video/cache/short0218/audio/approved-flow-84.m4a`,
  SHA256 `4f849b3d…3fa854e`).
- `bind-assets.py` anchors: replace the v0.2.18 literals with the bindings
  above.
- The camera/spot rules hold: the same named camera uses identical cells, and
  spotlights stay inside cameras.

`attention-check.mjs` works unchanged against `qa(t)`, `FILM_PLAN` and the
`.band`/`#frames .frame` DOM.
