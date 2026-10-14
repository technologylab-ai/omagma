# Synthetic calendar fixtures

These fixtures contain only fictional accounts and meeting links. They exercise
the independent received-invitation parser, request planning and bounded agenda
decoder through `src/calendar_tests.zig`; they never contact Google.

- `single-utc.ics`: source version, other attendees, escaped text, conferencing
  URL and an unknown property that must survive in the retained original.
- `all-day.ics`: exclusive end date across the Vienna autumn DST transition.
- `recurring-zone.ics`: authoritative embedded timezone plus RRULE, EXDATE and
  RDATE. The first import slice must preserve it and explicitly refuse to
  flatten the series into a single event.
- `cancellation.ics`: an organizer cancellation with no DTSTART; it must never
  turn into a new event.
- `agenda.json`: provider-expanded moved occurrence, stable original occurrence
  identity, all-day dates, unsafe join URI and a minimal deletion tombstone.

The test root also covers duplicate/hidden lookup behavior, incomplete pages,
account isolation, unknown-write reconciliation and conditional update headers.
Full runtime and live disposable-calendar acceptance belong to integration of
the host adapters, after the ordinary cooperative build reservation.

References: [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html),
[RFC 5546](https://www.rfc-editor.org/rfc/rfc5546),
[Calendar events](https://developers.google.com/workspace/calendar/api/v3/reference/events),
[event import](https://developers.google.com/workspace/calendar/api/v3/reference/events/import).
