# Create and edit Calendar events

Create timed or all-day events, invite guests and add a Google Meet or pasted
meeting link from the native Calendar view. Review the destination, times and
guest notifications before anything is saved. Events can also be
[deleted and invitations answered](#delete-events-and-answer-invitations) there.

## In the TUI

Open Calendar from the mail sidebar, then press `n` to create an event or `e` to
edit the selected event. Edit appears only for events the calendar itself
organizes; a meeting organized by someone else opens in Google Calendar with
`b`. Choose the destination account and writable calendar in
the editor. The destination is explicit even when the main view combines several
calendars or accounts.

Enter the title, dates, time zone and optional place or notes. Timed events show
start and end times. Times may be typed as `1430`, `2pm` or `14:30` (four digits
are HHMM only for an hour below 24 and minutes below 60, so `2026` is 20:26),
dates as `tomorrow`, `fri` (today's own weekday name means today), `+2d`,
`12-24` (a date already past this year means next year) or `2026-12-24`. End
date `+2d` counts from the Start date, and End time `+45m` or `+1h30m` from
Start; leaving the field shows the exact value that will be reviewed. `n`
starts today at the next half hour; once you have moved the selection to an
event it starts on that event's day, and in a range you navigated to it starts
on the range's first day. `c` starts a new event
copied from the selected one (title, place and times, never its identity). For an all-day event, the editor asks for the **last included
date** and converts it to Google's exclusive end date. If a clock change repeats
a local time, choose its first or second occurrence; the choices show the real
UTC offsets. A skipped time must be corrected before review.

Video choices are **None**, **Google Meet**, or **Paste link**. Meet is available
only when the selected calendar supports it. Paste a link from another meeting
service to include it in the event; Omagma does not create a Zoom or Teams room.
An existing conference stays attached when editing. Existing HTML notes are
preserved as read-only text rather than exposing raw markup for accidental edits.

Type guest addresses, or paste them as you would in a Mail recipient field: `Alex Example <alex@example.test>, "Doe, Jane" <jane@example.test>` works, and only the bare emails are sent to Calendar. A list holds at most 200 guests; a mailbox listed twice (even under different names) or an invalid entry is refused at review rather than dropped. While typing a name or email, suggestions appear after two letters from the destination account's cached Contacts and recent mail. Nothing is selected automatically: press Down or `Ctrl+N` to choose, then Enter or Tab to add. Up or `Ctrl+P` moves back; Esc hides suggestions for the current entry. Enter without a selected suggestion continues to the next control. Pasting keeps your text unchanged. You can also choose **Browse all** beside Guests (`Ctrl+Space` while editing Guests); an unfinished name becomes the picker's initial query, and choosing an address replaces that entry. The picker shows the destination account's loaded saved contacts together with its locally cached recent-mail recipients (the same cache Mail compose suggests from), even when Mail shows another account. Each email is an explicit choice; duplicates are merged case-insensitively, and recent correspondents are listed first so a large address book cannot hide them. Choose an address and **Add guest**; existing guests and their responses remain intact. `Esc` or **Back** leaves the form unchanged. Either source works without the other: without Contacts permission, recent mail still appears; without Mail access, saved contacts still appear; you can always type addresses manually. Typing filters only local data. The loaded contacts are the first page of the address book, so for anyone else press `Ctrl+F` or **Search Contacts**: one search of that account's Contacts for the typed text (at most 30 matches), shown alongside the loaded list. A miss in the loaded list reads **No loaded match**; only a search reports that no contact matches. Clearing the search text returns to the loaded list. If a contacts read omitted or only partly read some records, the picker says so on its own line: **Partial contacts · N omitted**, as Mail Contacts does, or **some were omitted or incomplete** when no count is given. A search miss then reads **No readable match**. An ordinary next page of contacts is not reported as partial. `Ctrl+R` refreshes contacts only. The picker never starts OAuth, fetches Sent mail, edits contacts or sends invitations.

Changing Start moves an End you have not edited, keeping the interval shown: a one-hour meeting stays one hour (wall-clock, also across a daylight-saving change), and an all-day event keeps its number of days. Partially typed or invalid start text leaves End alone. Once you edit End date, End time or the end's DST occurrence (even back to the same value), End stays exactly where you put it. A moved End drops its earlier DST occurrence choice; repeated or skipped DST wall times are still checked at review. Guests are one line: a line break in Guests is refused, as in Mail.

New guests imply invitation
emails. When editing an event that already has guests, explicitly choose whether
to notify them; adding guests notifies everyone. Existing guest responses remain
intact. Press `Ctrl+S` to review the exact destination, dates, guests and email
consequence, then `y` to confirm. The confirmation button spells out **Create &
email … guests**, **Save & email … guests**, or the explicit no-email choice.
Reviewing alone does not change Calendar or send invitations. A review without
guests does not mention guest emails. After the save, Back returns to the
Calendar view with the event selected and **Saved · title · time** in the status. `Esc` or **Cancel** closes an untouched form even while a read is pending. Modified forms ask before discarding; choose **Keep editing** or explicitly **Discard**. An event save already in progress finishes before you can leave.

Use `O` to open Calendar in the selected account's configured Chrome profile, or
`b` to open the selected event there. These browser actions are separate from
`o` Join, which opens the meeting URL in that account profile.

Press `g` to choose which calendars to show, including read-only subscriptions
such as holidays. `Space` toggles a source, `o` keeps only that source, `c` changes
its colour, and `Enter` applies the selection. In this picker, `a` switches between
the current account and all configured accounts. Combined views retain each
event's account/calendar identity and colours; creating or editing still selects
one explicit destination.

Checkboxes record which sources you want to show. A checked source without read
access says **Not shown · no read access** and can still be unchecked. You can
undo that change before applying. Apply
remembers that choice, independently of the same calendar listed under another
account. **Showing** counts readable sources currently displayed; **checked**
counts your pending choices, which take effect when you apply them.

In this picker, `p` marks one **Priority** calendar for the Week grid. When
several events share an hour row, Priority helps decide which one is shown;
`+N` still identifies the other events. The source legend marks it with `*`.
Priority belongs to the exact account and calendar, even when the same calendar
is shared into another account. A hidden Priority stays hidden. Marking it
changes neither permissions nor colours, and `p` can clear it even after read
access is lost. `Enter` applies the pending choice; `Esc` cancels it.


With the built-in **Omagma** theme, Calendar uses **Orange & Blue**: white event
text, vivid source colours and cool blue backgrounds. Press `Ctrl+T` in Agenda,
Day or Week to switch to **Classic**, the previous appearance. Press it again
to switch back; the choice is remembered. The Mail palette and each calendar's
chosen colour stay unchanged. Follow Omarchy and monochrome retain their own
appearance.

Week marks the current time with a red line across today’s column, using the
displayed time zone. The line stays visible beneath meeting titles and selected
events, and advances on the existing clock ticks. A red `now` label in the time
gutter identifies the line, replacing an hour label on that row when needed.
Monochrome uses an uncoloured line and label. They appear only when today and
the current hour are visible; the indicator does not
scroll the calendar or change the events shown. Its position is limited by the
terminal’s row resolution.

Week uses spare vertical space to show up to four distinct event titles in each
hour row. Its order favors non-declined events, events starting in that hour,
then your Priority calendar. `+N` counts events still hidden in that hour;
sharing an hour row does not necessarily mean their actual times overlap.

Click `+N` to list that exact hour's events, or use **Space · Show all** to list
events sharing the selected event's visible hour rows. All-day groups use their
own chooser. Every candidate shows its exact start/end dates and time zones,
calendar and account. `j`/`k`, arrows, Tab/Shift+Tab and the mouse work here.
**Enter · Select** reveals the chosen event in Week; the next ordinary Enter
opens its details. Esc restores the previous selection and controls.

An explicit selection can reveal an otherwise hidden event in one hour or
all-day bucket. Choosing a long event from 11:00 keeps that choice at 11:00 while
new meetings at 10:00 remain visible. Initial automatic selection keeps the
normal display order. Resizing uses the available space while retaining the
chosen event and civil-time bucket. The **Hidden here** preview counts only
alternatives absent from the displayed titles; **Show all** retains the full
candidate count. These choices change presentation and leave Calendar data,
reminders and the Mail account untouched.

## Delete events and answer invitations

In the Calendar view, `D` (or the Delete key) deletes and `r` answers (RSVP)
the selected event or the open event card. Each opens a dialog; neither key
changes Calendar by itself. The dialog reads the latest version of the event,
then shows its title, time, calendar, account, your role and guest count, the
choices and one sentence stating exactly what will happen, for example
**Deletes this event from Personal and emails 2 guests a cancellation.** `y`
(or the focused button) confirms; Esc, `q` and `n` leave everything unchanged.

`y`, Enter on the confirm button and a click confirm only what is on screen:
the event's title, time and calendar, that sentence and the button must all be
visible together in the finished frame (nothing drawn over them afterwards),
and only after that exact step (phase, scope, answer and email choice) has
been shown unchanged for a moment (0.6 s). A key typed ahead, a held key, a
changed choice, the second click of a double click or a dialog the terminal is
too small to draw never confirms; the status says what to do instead (**Let go,
look, then press y once more**, or enlarge the terminal). After a refused
confirm key, `y` acts only after 2 s without one, longer than any common
keyboard repeat delay, so holding `y` down never confirms however late the
terminal starts repeating it. When the
dialog does not fit, the event's title, time and calendar stay at the top and
the consequence just above the button while only the choices between them
scroll (on a short terminal the dialog may also use the key-hint row). An
answer or a single delete fits at 40x12; a step whose title, time and
consequence still do not fit (a long series answer, say) cannot be confirmed
there, and the status says **Enlarge the terminal**. A terminal too small for
the Calendar view does not open the dialog at all. The mouse wheel
only scrolls the dialog; it never moves the focus onto a button. The
confirmations for an identical retry and for archiving show the saved write's
own sentence (answer, scope and email, from the journal, also after a restart)
under the same rules, and their button names it (**[y Send Decline series again
· email organizer]**, **[y Delete again · email 2 guests]**). Their confirm
button sits on its own row, never on the cells of the **Retry** or **Archive**
button that opened them, so the second click of a double click lands on
**Back**. A due meeting card is not drawn over an open dialog: on the agenda the
status shows **Meeting due · M shows it** (after any **Enlarge the terminal**
note) and the card returns when the dialog closes; on an event card meetings
are not shown, so nothing is promised there. If `M` brings the card up, keys go
to the card and the dialog cannot be confirmed until the card is gone and the
dialog has been seen again. A card that returns (after a dialog, Help, another
page or a too-small terminal) waits 0.6 s before its keys and buttons act, so
the second click of a double click on the dialog's button never joins or
dismisses a meeting.

| Situation | Delete | RSVP |
| --- | --- | --- |
| This calendar organizes the event and it has guests | Choose **Email N guests a cancellation** or **Don't email the guests** before `y` is available | No RSVP: `r` explains that organizers have nothing to answer |
| Organized here, no guests | Deleted without email | No RSVP |
| You are invited | **Removed from your calendar only**; the organizer's event stays and Omagma sends no email (Google may still show the organizer that you removed it). To say you won't attend, decline instead | `a` Accept, `m` Maybe, `x` Decline choose; `y` sends; the current answer cannot be resent |
| Someone else's event without your guest entry | Removed from this calendar only | Not invited: nothing to answer |
| A shared or delegated calendar | The dialog names the calendar instead of "you" (**Shared team organizes it**, **Remove from this calendar?**): removing it removes it for everyone who sees that calendar | Answered only for this account's own guest entry |
| Repeating event | **This event only** (default) or **All events in the series**; each shows its own facts (below) | the same two scopes |
| Read-only calendar, locked, special (focus time, out of office, birthdays) or private copy | Disabled with the reason; `b` opens Google Calendar | Disabled with the reason; a private copy is answered from its mail (`I`) |
| Calendar write permission missing | Disabled; Enter shows the copyable authorization command that keeps your current capabilities | the same |

*This and following events* is not offered; use Google Calendar (`b`) for it. A
changed occurrence can have its own title, time, guests and answer, so the
dialog always shows the facts of what the chosen scope writes: **This event
only** shows the occurrence, **All events in the series** shows the series
itself (its title, **Repeats daily · from …**, its guests and its answer), and
switching scope asks again whether Google emails the guests. Before sending,
the exact review is compared with everything the dialog showed (version, role,
guest count, answer, scope and email choice); any difference shows the event
again and sends nothing. A series answer may leave occurrences you answered
separately with their own answer. **Email my answer to the organizer** is on by
default; turned off, Google saves your answer on the shared event without email,
which an organizer using Google Calendar still sees. Omagma never composes the
email itself.

Every write is conditional on the version the dialog showed (`If-Match`): when
someone changed the event meanwhile, Calendar refuses it, nothing changes and the
dialog says so. A choice Calendar refuses (for example nobody left to email, or
an answer that is already saved) shows the reason and the current facts to
choose again. A confirmed delete removes the event from the view at once, an
answer updates its `?`/`~`/`×` mark (a series answer on every loaded occurrence
of the series), and the range then reloads from Google (from an event card, as
soon as the agenda shows again). The status says only what Omagma knows:
**Deleted · title · time · Google was asked to email 2 guests a cancellation**,
**Removed from Personal · …**, **Declined · … · Google was asked to email the
organizer**. A delete settled by checking reads **Calendar shows it cancelled**
and claims no email, since any cancellation proves it. There is no undo: Omagma
cannot prove a restore, and a sent cancellation cannot be recalled.

If Calendar does not confirm the outcome (a lost connection), the dialog stays
**unconfirmed** and never guesses. `r` checks Calendar with reads only: a
deleted (cancelled) event or your saved answer settles it. When Calendar still
shows the unchanged version, `Ctrl+R` offers to send the identical request once
more after its own confirmation; its unchanged `If-Match` cannot touch a newer
version. `Ctrl+D` stops tracking the uncertainty after a warning that the change
may already have happened. Once apply has claimed the write, any failure (a lost
connection, the 30-second deadline, a full disk while recording the outcome) is
unconfirmed, never "nothing was changed". An unconfirmed change blocks other
changes that it could overlap (see below) and survives a restart: one to an
occurrence (an edit too) blocks a series change; one to the whole series blocks
every occurrence and is resumed by `D` or `r` on any of them. The dialog opens
exactly the write that refused it and names its event: an unconfirmed edit of
another occurrence reads **An unconfirmed edit of “Standup” · Thu 12 Nov … is
saved · open that event and press e to check it**. If that write cannot be
found it checks the event once more, then stops and says so instead of reading
again. When an invitation's own Calendar update (from Mail) is the unconfirmed
write, the dialog names it and resolves it in place: `r` checks Calendar with
reads only, and `Ctrl+D`, after its own confirmation, stops tracking it once
you have checked Google Calendar (nothing is sent either way); then the event
is checked again. The event editor names such a write too (**Esc, then D or r
on the event checks it**) and stays silent about writes to other occurrences,
which never overlap an edit of this one.

### From the CLI

Both actions follow the review → apply contract of `calendar event-review`.
A dry run (`--dry-run`, JSONL `dryRun:true`) reads only, saves nothing and needs
no ETag; it returns the role, guest count, current answer, `consequence` and
`options` (`series`, `notify`, `thisAndFollowing`) for choosing the real review:

```sh
omagma calendar event-delete-review --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID \
  --scope event --send-updates none --operation-id PLAN_ID --dry-run
omagma calendar event-delete-review --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID \
  --expected-etag RETURNED_ETAG --scope event --send-updates all \
  --operation-id UNIQUE_DELETE_ID
omagma calendar event-apply --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --operation-id UNIQUE_DELETE_ID \
  --review-hash RETURNED_REVIEW_HASH
```

`calendar event-respond-review` takes the same fields plus `--response
accepted|tentative|declined` (`--response` on a delete, or `--scope` on other
Calendar verbs, is a usage error, status 2). `--scope series` binds the series
master's own ETag (`targetEventId`/`targetEtag` in the review) and reports the
series' own facts (`summary`, `start`/`end`, `recurrence`, `role`, `guestCount`,
`previousResponse`); a dry run on an occurrence returns the occurrence's facts
plus the series' facts under `options.series`. `ownCalendar:false` marks a shared
or delegated calendar. `--send-updates all` is
accepted only where somebody can be notified: guests of an event this calendar
organizes, or the organizer of an invitation. The saved review is applied,
checked, retried and archived with `calendar event-apply`, `event-reconcile`,
`event-retry` and `event-abandon`; `event-apply --dry-run` repeats apply's fresh
checks and reports `wouldSend` without sending (the other commands have no dry
run: a usage error). One-shot exit status follows the state: 0 applied, 3
rejected or refused, 4 missing permission, 6 unknown. A failed `event-retry`
exits 6 (its earlier write stays unknown) unless it was refused for
authorization (4), found no saved write (5, e.g. `CalendarReviewNotFound`) or
was malformed (3, an `Invalid…` code).

**Which writes wait for an unconfirmed one.** Every Calendar write records the
event it writes, the occurrence a series action was chosen on and the event's
provider series (Google's `recurringEventId`, never guessed from the event ID's
text, so split series such as `abc_R20261111T150000` and IDs starting with `_`
are kept apart). Two writes overlap when they name the same event, or when one
changes a whole series that the other's event belongs to (or is). An
unconfirmed (unknown) write blocks every overlapping write, in both directions
and of every kind: deletes, answers, edits in the event editor and an
invitation's own update or cancellation. The check runs when the review is made
(dry runs included), again before apply and once more under the journal lock
when the write is claimed. One-off changes to different occurrences of a series
do not block each other. A refusal is `CalendarOperationPending` with
`blockingOperationId` (and `blockingKind`, `event` or `invitation`).

`calendar event-pending --operation-id ID` opens exactly that write.
`--event-id ID` finds the write that blocks the event: one to the event itself or
its whole series (for a series ID, one to any of its occurrences), and then, as
`relation: series`, one to another occurrence, which blocks a series action
there. Pass the event's `recurring_event_id` as `--series-event-id` (`""` when
it does not repeat); without it the event is read once to learn its series, and
`seriesChecked:false` with `readError` says when that read failed.
`--series-event-id ID` alone finds the writes on that series: the series
itself, a whole-series write or one to any of its occurrences (reads nothing);
`--series-event-id ""` needs `--event-id`. Without any of these the lookup
finds an unconfirmed creation. An invitation's own unknown update is reported
as `blockedBy` (`operationId`, `reviewHash`, `uid`, `eventId`, `summary`,
`previous`): `calendar event-reconcile` with that operation ID and hash checks
it with reads only, and `calendar event-abandon` stops tracking it when a check
cannot settle it (both also accept it from `calendar reconcile`'s review).
Invitation updates are checked for overlapping unconfirmed writes when they are
reviewed, too; an identical `event-retry` waits for any other overlapping
unconfirmed write as well.

Downgrading is not supported once 0.2.19 has saved a Calendar review: 0.2.18
reads the Calendar journal strictly and refuses it as a whole (`UnknownField`)
because of fields it does not know, such as saved delete/RSVP reviews and
invitation reminders. Its commands that use the journal (reviews, apply, checks,
invitation plans) then fail instead of misreading it, so 0.2.18 can neither
resend nor drop an unconfirmed write. Reinstalling 0.2.19 resumes everything;
nothing is lost.

Google calls: a review reads the event with `events.get` (and its series
master for a series action or an occurrence's dry run); apply reads it once more
and then sends exactly one `events.delete` with `If-Match` and `sendUpdates`, or
one `events.patch` with `If-Match`, `sendUpdates`, `attendeesOmitted:true`, only
this calendar's attendee entry and private receipt markers. Checking an
uncertain outcome uses `events.get` only. Both actions use the existing
`calendar-write-owned` or `calendar-write-shared` permission (OAuth scope
`calendar.events.owned` or `calendar.events`); no new scope is requested.

## Booked appointments received by email

A booking confirmation may contain a Calendar attachment with no guest list.
Press `A` **Calendar** to open a compact confirmation for the receiving email
account's primary calendar. Omagma checks for an existing copy and saves the
exact review before enabling **Add appointment**. There is one confirmation;
press `y`, or focus the button and press Enter. Long notes must be read first.
`v` **Details** reveals protocol identifiers and complete provider errors.

The copy is your own appointment: Google requires the calendar owner to be its
organizer or an attendee. No guest is invented. The original booking organizer
and source UID remain recorded, along with the title, exact times, time zone,
location and notes. No email or RSVP is sent. This route requires the account's
verified writable primary calendar; secondary/shared destinations are refused.
Missing or read-only primary access is explained in the same card.
Normal Mail invitations retain their own attendee/organizer semantics.
Personal copies do not automatically apply later booking updates or cancellations;
when the source differs from the saved copy, check Calendar rather than adding a
second appointment.

This is separate from accepting a meeting invitation. Messages listing another
attendee still require a matching account or verified alias. Existing recurrence,
ambiguous-event, cancellation and timezone review limits remain in effect.
After the appointment is added, `q` returns to the mail where you pressed `A`.

## Invitation times without a usable zone

An invitation whose time names an unknown zone (Outlook's `W. Europe Standard
Time`), carries embedded zone rules Omagma cannot match, or has no zone at all
(floating) is never added by guessing. The review shows the wall clock exactly
as written and a candidate: the mapped zone for a Windows name, otherwise the
destination calendar's zone, offered only when it resolves the written times.
Nothing is assumed until you press `z` (or focus **[z Use …]** and press Enter)
or `Z` to type a zone; a bare Enter only explains the choice. Only the endpoints
without a usable zone take your choice, and an end in a valid zone keeps it.
For a named zone this is an explicit reinterpretation for this review only
(`reinterpretEmbeddedTimezones` in the CLI request); for a floating time it is
the consent to fix it (`acceptFloatingTime`). Calendar then checks the times in
that zone, the review states what you chose (**You chose to read its times as
Europe/Berlin.**), and the usual Review and `y` confirmation follow.

## Other calendar attachments

Named `.ics` attachments also work when the sender labels them `text/plain` or
uses an uppercase `.ICS` extension. Published, attendee-free events and ordinary
calendar files without `METHOD` use the same primary-calendar confirmation flow
as booked appointments. They create a personal event, with no guests or RSVP.
Opening or reviewing a file does not add it.

The review preserves the event's dates, title, place and full notes. An all-day
end date is exclusive in iCalendar and Google; the card shows only included days.
Supported DISPLAY alarms become Google popup reminders, shown before confirming.
Unsupported alarms are disclosed and never executed. This includes email/audio,
absolute, repeating and nominal day/week alarms; nominal days can differ from
elapsed minutes at a daylight-saving change. With no source alarm, the calendar's
default reminders apply. Limits remain one non-recurring event per import,
128 KiB of source, at most five supported reminders and four weeks before start.

The standard meeting invitation and RSVP flow is separate and retains its
verified-attendee checks. Calendar attachments do not infer an invitation from
a join link, invent guests, or turn a published notice into a meeting request.

## Permissions

Calendar creation, editing, deleting and answering invitations use the existing
optional `calendar-write-owned` or `calendar-write-shared` permission. No Meet-specific
OAuth permission is required to create a Google Meet conference attached to a
Calendar event. Automatic Meet AI notes additionally need the optional
`meet-settings` permission (see below). The existing account grant must also
include calendar-list access. See [Calendar permissions](CALENDAR-PERMISSIONS.md) before changing a
grant; preserve the complete existing desired capability set.

Ordinary creation makes the selected calendar the organizer. This is separate
from importing an invitation, which retains an attendee copy.

## CLI review before applying

Start with `omagma calendar list --account personal@example.com`, then select the
exact returned calendar ID. Read `omagma calendar event-review --help` or
`omagma cli --help calendar.event-review` for the complete local command contract.

A bare `event.json` can contain:

```json
{
  "summary": "Project planning",
  "start": "2026-10-22T10:00",
  "end": "2026-10-22T11:00",
  "timeZone": "Europe/Vienna",
  "description": "Review the next milestone.",
  "attendees": ["colleague@example.com"],
  "conference": "google_meet"
}
```

```sh
omagma calendar event-review --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --event-file event.json \
  --send-updates all --operation-id UNIQUE_REVIEW_ID
```

Inspect the returned account, calendar name/ID, event details, resolved times,
notification policy and previous event, if any. The review only reads provider
state and saves a local review; it does not create or update an event.

```sh
omagma calendar event-apply --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --operation-id UNIQUE_REVIEW_ID \
  --review-hash RETURNED_REVIEW_HASH
```

The result contains `state: applied`, `rejected` or `unknown`. Inspect it even
when the outer command envelope reports `ok: true`. Unknown means the response
could not prove whether the provider accepted the exact write. Resolve that
saved operation with `calendar event-reconcile` and the same account, calendar,
operation ID and review hash. Reconciliation only reads; it never resends guest
invitations or repeats a conference creation request. A pending unknown creation
blocks another creation in the same calendar, including under a different ID.

If checking still leaves an unknown result, the TUI offers `Ctrl+R` to retry the
**identical saved request** and `Ctrl+D` to archive the uncertainty. Each action
opens its own warning and requires explicit confirmation. A retry retains the
original event ID, guest notifications, Meet request ID and edit `If-Match`;
repeating the same retry token cannot send again. Nothing retries automatically.
A missing event or unchanged ETag is still uncertainty, since the original
request may arrive late. Archiving means **the event may still appear in
Calendar**; it does not mean the event was unsent. It releases the pending guard
and prevents applying that saved form again.

Closing and reopening the TUI retains recovery. Creating an event again in the
same destination, or editing the affected event, restores the saved operation.
CLI callers can use `calendar event-pending --calendar-id ID` (add `--event-id
ID` for an edit, with `--series-event-id` as above). It returns `pending: null`
or the saved review and attempt number; only an event ID without its series is
read from Google. `calendar event-reconcile` returns
`retryPossible` and `nextAttempt`; an explicitly confirmed `calendar event-retry`
requires that number as `--next-attempt`. `calendar event-abandon` archives the
uncertainty locally. Both keep the original account, calendar, operation ID and
review hash.

## Dates, time zones and editing

Timed events accept a local `YYYY-MM-DDTHH:MM[:SS[.mmm]]` and an explicit IANA
zone. Nonexistent local times at a daylight-saving jump are refused. An ambiguous
local time at a daylight-saving fold requires `startOffset`/`endOffset`, such as
`+02:00` or `+01:00`. Offset-bearing RFC3339 timestamps are also accepted when
their offset agrees with the named zone. No machine-timezone fallback or silent
fold choice occurs. Editor prefill preserves original seconds, milliseconds and
selected offsets.

An all-day event uses `allDay: true` and civil dates. Its end is exclusive: a
single event on October 25 uses start `2026-10-25`, end `2026-10-26`. It remains
one civil date even across a 23-hour or 25-hour day.

To edit, read the exact event with `calendar event`. It returns `canEdit` and
`eventDraft` along with the event's provider `etag`. Supply its `eventId` and
`expectedEtag` when preparing the new review. Apply rechecks the current ETag and
uses `If-Match`; a changed provider event requires a fresh review. Changing a time
moves the exact event, preserving its identity. Other provider properties,
attachments and existing conference data are left intact.

The initial editor supports organizer-owned normal events and exact recurring
occurrences. It refuses attendee copies, locked/private copies, special event
types and whole recurring series. Use the account-profile browser opening action
for those cases.

## Guests and conferencing

| Choice | Behavior |
| --- | --- |
| `attendees` omitted | Preserve the complete existing guest list and RSVP attributes. |
| Existing guests plus new email addresses | Preserve existing attendee objects and invite the new guests; requires `sendUpdates: all`. |
| Removing an existing guest | Refused by this initial editor. |
| `sendUpdates: all` | Ask Google to notify all participants, including about a moved time. |
| `sendUpdates: none` | Explicitly suppress update notifications; unavailable when adding guests. |
| `conference: none` | Create without a new conference, or preserve an existing conference on edit. |
| `conference: google_meet` | Request a unique conference when the selected calendar advertises `supports_meet`. |
| `conference: link` | Append the safe HTTPS `joinUrl` to the invitation description. No third-party meeting API is called. |

The event write binds the selected account, calendar, guest list, notification
choice and conference request into one saved review. Existing conference links
are preserved rather than silently replaced. Google can finish conference
creation asynchronously: an event can be saved while `conference_status` is
`pending`, or remain saved with status `failure`. Refresh that event to see its
status and `join_url`; do not recreate it to obtain a link. If Meet is unavailable
for the calendar, use a pre-existing meeting URL or create an event without a
conference.

Google documents the event creation and conference request fields in
[events.insert](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert),
conference availability in
[CalendarList](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList),
and asynchronous conference states in
[Events](https://developers.google.com/workspace/calendar/api/v3/reference/events).
Google warns that suppressing guest updates can affect external calendar
synchronization; `all` is the appropriate ordinary invitation/rescheduling choice.

## Storage and browser opening

Saved reviews and receipts use the account's selected private store. Encryption
applies when that store is the unlocked vault; legacy private storage remains
plaintext. Passwords and tokens are not added to request JSON or logs.

`calendar open` opens the selected account in its configured Chrome profile.
`calendar event-open --calendar-id ID --event-id ID` opens the exact event in that
same account profile. This is separate from `o` Join, which opens the conference
URL. Calendar browser links are validated before launching the browser.

## Version compatibility

Event creation and editing require Omagma v0.2.10 or later.
Use one version against a given private store: v0.2.9 cannot read the new
ordinary-event journal or customized Calendar visibility/color preferences.
Existing v0.2.9 invitation and RSVP reviews, including uncertain outcomes, are
recognized when upgrading. Switching back to v0.2.9 with that updated store is
unsupported.

## Automatic Meet AI notes

Auto Meet AI notes + transcript. When you create a new event with Google Meet on the account’s primary calendar, check this box to have Google take AI notes and a transcript automatically when you or a co-host joins Meet on the web, subject to participant consent and admin policy. Unchecked sends no Meet setting, so Google's or your admin's defaults apply. It needs the optional meet-settings permission: if it is missing, Ctrl+S opens a guide that keeps your form and copies an authorization command keeping your current capabilities; Ctrl+R rechecks after you run it. Google also requires the Meet REST API to be enabled in your Cloud project and a Workspace plan and admin policy that allow AI notes. The event is saved first. Success means Google's read-back showed both settings on at that time; they can change later. If the Meet link is still being created, r checks with reads only, and y sends the setting once the link is ready. If Google refuses, or the outcome is unconfirmed, the event stays saved and Omagma says so; nothing is resent automatically, so check AI notes in Meet when you join. Esc keeps the saved status; check it later with omagma calendar meet-event-pending and meet-event-reconcile. Omagma never joins or monitors the meeting.

### From the CLI

The Meet commands create new events only, on the account's primary calendar.
Check `accounts.list` for `meet-settings` and a Calendar write capability. Then
choose the entry whose `calendar.primary` is true from
`omagma calendar list --account personal@example.com`. A bare `meeting.json`
uses the ordinary event fields and must request Google Meet:

```json
{
  "summary": "Project kickoff",
  "start": "2026-10-22T10:00",
  "end": "2026-10-22T10:45",
  "timeZone": "Europe/Vienna",
  "attendees": ["colleague@example.com"],
  "conference": "google_meet"
}
```

```sh
omagma calendar meet-event-review --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --event-file meeting.json \
  --meet-ai-notes on --send-updates all --operation-id UNIQUE_MEET_EVENT_ID
```

`--meet-ai-notes on` is the only setting: it turns on AI notes and
transcription together. The review reads provider state and saves a local
review; it creates no event and sends nothing. Inspect the account, calendar,
resolved times, guests and `sendUpdates`, then confirm with the returned hash:

```sh
omagma calendar meet-event-apply --account personal@example.com \
  --calendar-id RETURNED_CALENDAR_ID --operation-id UNIQUE_MEET_EVENT_ID \
  --review-hash RETURNED_REVIEW_HASH
```

Apply creates the event (with `--send-updates all`, Google emails the guests),
then sends the AI notes setting to its Meet link. Inspect `state`,
`meetAiNotes.state` and `current` even when `ok` is true:

| Result | Meaning and next step |
| --- | --- |
| `state: applied`, `meetAiNotes.state: on` | The event was created and Google's read-back (`current`) showed both settings on at that time. |
| `state: partial` | The event is saved, but AI notes are not confirmed; `meetAiNotes.state` and `reason` say why. Do not create the event again. |
| `meetAiNotes.state: waiting_for_link` | The Meet link is still being created. Check with `meet-event-reconcile`; once it reports `meetAiNotes.phase: ready`, run `meet-event-apply` again with the same operation ID and review hash. That sends only the first Meet settings request and never writes Calendar again. |
| `meetAiNotes.state: refused` | Final for this operation; it does not show the current setting. The event stays saved, so check AI notes in Meet. |
| `state: unknown` or `meetAiNotes.state: unknown` | Run `meet-event-reconcile`. Never retry under a new operation ID or create the event again; an unknown AI notes outcome is never resent. |
| `state: rejected` | Calendar refused the event and nothing was changed. |
| `state: not_sent` | No request reached Google. |

`meet-event-reconcile` takes the same account, calendar, operation ID and review
hash. It sends only Google reads; it never writes Calendar, changes Meet
settings or emails guests. After a restart,
`omagma calendar meet-event-pending --account personal@example.com --calendar-id RETURNED_CALENDAR_ID`
shows the saved operation from the local journal without contacting Google.
`calendar event --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID`
returns the created event's Meet URL; emailing it to a thread is a separate, explicitly authorized `mail reply`.
JSONL callers use the same command names; see
`omagma cli --help calendar.meet-event-review`.
