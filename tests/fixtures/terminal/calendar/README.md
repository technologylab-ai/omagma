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
- `legacy-029-update.json` and `legacy-029-rsvp.json`: genuine durable documents
  produced by the published v0.2.9 Linux x86_64 executable, using only the
  synthetic provider. Each flow first imports an invitation, then commits a
  Calendar mutation whose response is lost. The second fixture updates only
  the attendee's tentative response. Both retain an unknown operation and its
  original non-null previous-event snapshot, before newer event fields existed.
  The wrapper contains the original account state, provider state and exact
  confirmation; Python retained those JSON documents without serializing them
  through newer application types. The generating executable reported Zig
  0.17.0/Safe and its published-checksum-verified SHA-256 was
  `ddf097bf72bba4fed2317accf9f5612e567ac05d9e9519ec3e0e8e58e7760bec`.

The test root also covers duplicate/hidden lookup behavior, incomplete pages,
account isolation, unknown-write reconciliation and conditional update headers.
Full runtime and live disposable-calendar acceptance belong to integration of
the host adapters, after the ordinary cooperative build reservation.

References: [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html),
[RFC 5546](https://www.rfc-editor.org/rfc/rfc5546),
[Calendar events](https://developers.google.com/workspace/calendar/api/v3/reference/events),
[event import](https://developers.google.com/workspace/calendar/api/v3/reference/events/import).
