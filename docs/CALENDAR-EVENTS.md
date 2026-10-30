# Create and edit Calendar events

Create timed or all-day events, invite guests and add a Google Meet or pasted
meeting link from the native Calendar view. Review the destination, times and
guest notifications before anything is saved.

## In the TUI

Open Calendar from the mail sidebar, then press `n` to create an event or `e` to
edit the selected event. Choose the destination account and writable calendar in
the editor. The destination is explicit even when the main view combines several
calendars or accounts.

Enter the title, dates, time zone and optional place or notes. Timed events show
start and end times. For an all-day event, the editor asks for the **last included
date** and converts it to Google's exclusive end date. If a clock change repeats
a local time, choose its first or second occurrence; the choices show the real
UTC offsets. A skipped time must be corrected before review.

Video choices are **None**, **Google Meet**, or **Paste link**. Meet is available
only when the selected calendar supports it. Paste a link from another meeting
service to include it in the event; Omagma does not create a Zoom or Teams room.
An existing conference stays attached when editing. Existing HTML notes are
preserved as read-only text rather than exposing raw markup for accidental edits.

Type guest addresses, or paste them as you would in a Mail recipient field: `Alex Example <alex@example.test>, "Doe, Jane" <jane@example.test>` works, and only the bare emails are sent to Calendar. A list holds at most 200 guests; a mailbox listed twice (even under different names) or an invalid entry is refused at review rather than dropped. Or choose **Contacts · recent mail** beside Guests (`Ctrl+Space` while editing Guests). The picker shows the destination account's loaded saved contacts together with its locally cached recent-mail recipients (the same cache Mail compose suggests from), even when Mail shows another account. Each email is an explicit choice; duplicates are merged case-insensitively, and recent correspondents are listed first so a large address book cannot hide them. Choose an address and **Add guest**; existing guests and their responses remain intact. `Esc` or **Back** leaves the form unchanged. Either source works without the other: without Contacts permission, recent mail still appears; without Mail access, saved contacts still appear; you can always type addresses manually. Typing filters only local data. The loaded contacts are the first page of the address book, so for anyone else press `Ctrl+F` or **Search Contacts**: one search of that account's Contacts for the typed text (at most 30 matches), shown alongside the loaded list. A miss in the loaded list reads **No loaded match**; only a search reports that no contact matches. Clearing the search text returns to the loaded list. If a contacts read omitted or only partly read some records, the picker says so on its own line: **Partial contacts · N omitted**, as Mail Contacts does, or **some were omitted or incomplete** when no count is given. A search miss then reads **No readable match**. An ordinary next page of contacts is not reported as partial. `Ctrl+R` refreshes contacts only. The picker never starts OAuth, fetches Sent mail, edits contacts or sends invitations.

Changing Start moves an End you have not edited, keeping the interval shown: a one-hour meeting stays one hour (wall-clock, also across a daylight-saving change), and an all-day event keeps its number of days. Partially typed or invalid start text leaves End alone. Once you edit End date, End time or the end's DST occurrence (even back to the same value), End stays exactly where you put it. A moved End drops its earlier DST occurrence choice; repeated or skipped DST wall times are still checked at review. Guests are one line: a line break in Guests is refused, as in Mail.

New guests imply invitation
emails. When editing an event that already has guests, explicitly choose whether
to notify them; adding guests notifies everyone. Existing guest responses remain
intact. Press `Ctrl+S` to review the exact destination, dates, guests and email
consequence, then `y` to confirm. The confirmation button spells out **Create &
email … guests**, **Save & email … guests**, or the explicit no-email choice.
Reviewing alone does not change Calendar or send invitations. `Esc` or **Cancel** closes an untouched form even while a read is pending. Modified forms ask before discarding; choose **Keep editing** or explicitly **Discard**. An event save already in progress finishes before you can leave.

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

## Permissions

Calendar creation and editing use the existing optional
`calendar-write-owned` or `calendar-write-shared` permission. No Meet-specific
OAuth permission is required to create a Google Meet conference attached to a
Calendar event. The existing account grant must also include calendar-list
access. See [Calendar permissions](CALENDAR-PERMISSIONS.md) before changing a
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
ID` for an edit). It returns `pending: null` or the saved review and attempt
number without contacting Google. `calendar event-reconcile` returns
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
