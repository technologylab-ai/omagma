# Omagma v0.2.19 — social post copy

Film: **In Good Time** (`video/short0219/film.html`, 84.233 s, approved v0.2.7
soundtrack unchanged). Each feature is announced, then shown in the genuine
app. Copy by actual Claude Opus 5.5 at xhigh.

## Post

Omagma v0.2.19 is out 🌋 Your calendar is now a real Day and Week grid, in a
fresh orange & blue look. Guests are suggested as you type, you can RSVP right
from the grid, bill reminders arrive from emailed .ics files, and discarded
drafts come back with Ctrl+Z. All from the terminal.

New since v0.2.18:

- **Day and Week grids.** Events are blocks on a time axis. Overlaps sit side
  by side, all-day events get their own band and the red now line marks today.
- **Orange & Blue Calendar look.** It matches Omagma's Mail. Ctrl+T switches
  to Classic and back, and Omagma remembers your choice.
- **Guest suggestions after two letters**, from your cached Contacts and recent
  mail. Nothing is picked for you: ↓ chooses, Enter adds. Ctrl+Space browses
  them all.
- **RSVP and delete from Calendar.** Press r or D for a review that names the
  event and who gets emailed. Nothing changes until you confirm.
- **Personal events from emailed .ics files.** Press A to add a bill due date
  or another published event to your calendar, with its all-day dates and popup
  reminders.
- **Undo a discarded draft.** Ctrl+X asks first. Ctrl+Z brings it straight
  back, or :restore-draft does it later, even after a restart, for up to 7 days.

Smaller wins:

- Reconnect an expired account right in the TUI with Ctrl+O or :reconnect,
  with Google's reason shown first
- Clearer Sent dates and recipient names, aligned reader fields, friendly
  label chips
- n/N jumps between unread mail; g then i/s/d/a/t opens a mailbox, with a hint
  in the footer
- Escape backs out without quitting
- Unusual headers, character sets and calendar details no longer hide a whole
  message or view
- Emoji and full-repaint fixes keep Mail ↔ Calendar switches aligned
- CLI: strict unknown-field errors, real dry runs, compact help, one-call
  replies and a complete Meet AI notes recipe for agents

TUI and CLI are experimental. Linux & macOS.
👉 technologylab-ai.github.io/omagma

## Short variant (≤280 characters)

Omagma v0.2.19 🌋 Your calendar is now a real Day/Week grid in orange & blue.
Guests suggested as you type, RSVP from the grid, bill reminders from emailed
.ics files, and Ctrl+Z brings back a discarded draft.
technologylab-ai.github.io/omagma

## Copy decisions

- The .ics example is a personal bill due date. It is neither a meeting
  invitation nor a repeat of the v0.2.18 haircut. No "no email sent" claim is
  made as a generic Calendar benefit.
- Guest copy stresses the deliberate choice. Nothing is auto-selected, typing
  sends no invitation and suggestions come from local cached data.
- The RSVP and delete copy says nothing changes until you confirm. It does not
  claim a write before confirmation, and it makes no undo claim for Calendar
  changes.
- Draft restore is scoped to the last discarded draft per account, for up to 7
  days. It makes no claim about Gmail drafts.
- The now line appears as calendar context, not as a new feature.
- Fixtures, demo data and production provenance belong in the production
  records, not in the post.
