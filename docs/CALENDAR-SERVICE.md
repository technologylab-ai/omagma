# Calendar service host contract

`src/terminal/calendar_service.zig` is the shared command implementation for
native terminal hosts. It does not open credentials, choose storage paths, or
perform HTTP by itself. Core routes native Calendar commands through
`calendar_host.zig`, which supplies the account, authorization, transport and
storage adapters. The TUI and CLI use this shared integration.

| Host command | Service call | Result |
| --- | --- | --- |
| `calendar.list` | `Service.list()` | Account-bound calendars and explicit completeness |
| `calendar.agenda` | `Service.agenda(calendar, window)` | Complete fresh snapshot, or the exact previous snapshot marked stale with a refresh error |
| `calendar.event` | `Service.event(calendar, event_id)` | One event, including description and safe links |
| `calendar.invitation-plan` | `Service.invitationPlan(calendar, source, verified_aliases, bindings)` | Preserved source, parsed times, complete UID lookup, tracked state, and a decision |
| `calendar.review` | `Service.prepareReview(planned, operation_id)` | Exact request bytes and a review hash; no provider mutation |
| `calendar.apply` | `Service.apply(review, confirmation)` | Applied, rejected, or unknown durable outcome |
| `calendar.reconcile` | `Service.reconcile(review)` | Read-only reconciliation of an existing durable operation |
| `calendar.event-review` | `Service.prepareEventReview(...)` | Ordinary organizer creation/edit review; no provider mutation |
| `calendar.event-apply` | `Service.apply(review, confirmation)` | Single-dispatch ordinary event save with reviewed guest notifications |
| `calendar.event-reconcile` | `Service.reconcile(review)` | Exact event-ID recovery; never repeats invitations |
| `calendar.event-retry` | `Service.retry(review, confirmation, nextAttempt)` | Explicit identical-request retry with a durable single-use attempt token |
| `calendar.event-abandon` | `Service.archive(review, confirmation)` | Local archived uncertainty; the event may still appear |
| `calendar.event-pending` | Durable pending-review callback | Restore an unknown ordinary create/edit without credentials or provider traffic |
| `calendar.freebusy` | `Service.freeBusy(calendar, window)` | Busy ranges, or an explicit incomplete result for a per-calendar error |

Use one bounded request arena per command. Retain a review in the account's
durable store or copy it into an owned bounded session arena while a TUI
confirmation is pending. Never leave borrowed request-arena strings in the UI.
`windowForDays` resolves a local day or seven-day window using the supplied zone;
it preserves 23-hour and 25-hour days. Agenda requests ask Google to expand
recurrences in that bounded window. Source recurrence writes remain unavailable. Ordinary organizer creation, guest invitations, Google Meet creation and exact occurrence edits use a separate [event draft contract](CALENDAR-EVENTS.md).

## Native transport

Construct `Grants` from the selected account's validated terminal grant, and
construct calendars from the service list. The transport receives a prepared
`calendar_provider.Request`. It must select credentials for `request.target.account`,
honor the HTTP method, JSON body and optional `If-Match`, and return the verified
credential account, raw status and bounded response body. Use the host's existing
single network worker. Do not perform automatic retries for mutations or follow
redirects. Calendar 404 remains `CalendarNotFound`; it must not go through a Gmail
dispatcher that interprets 404 as missing mail or invalid account authorization.

`calendar_native.Native` supplies that production transport. Initialize it in
stable caller storage with the command, request, configured account and request
and buffer allocators. Its shared `NetworkSession` initializer checks the command's
Calendar capability alternatives before client, credential or network access,
then verifies the actual profile through the existing terminal authorization
path. `Native.transport()` and `Native.grants` feed the service. `Native.close()`
wipes the session's existing secret and response buffers. Core must keep the
native session alive for the complete synchronous service call.

`http_client.requestCalendar` has a separate authority/path policy for
`https://www.googleapis.com/calendar/v3/`; the generic terminal and bar policies
remain unchanged. PATCH and DELETE require an exact quoted ETag transmitted as
`If-Match`. Redirects and weak/wildcard/injected conditional values are refused.
Only reads may refresh and retry a definitive 401 once; mutations receive the
raw response for the service to journal.
[Google conditional modification and 412 responses](https://developers.google.com/workspace/calendar/api/guides/version-resources).

Read and write checks combine OAuth grants with calendar access. Primary status
or a matching `dataOwner` proves owned-scope coverage; ACL `owner` alone does not.
The `dataOwner` field applies to secondary calendars. A busy-only calendar needs
the availability capability and is never an import destination.
[Google CalendarList resource](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList),
[FreeBusy authorization](https://developers.google.com/workspace/calendar/api/v3/reference/freebusy/query).

## JSON command integration

`calendar_commands.dispatch(service, request, host)` is the common JSON boundary.
It does not instantiate credentials or storage. Core supplies an initialized
native service and `HostInputs { io, env, context, loadInvitationFn,
loadReviewFn, loadReceiptFn, loadPendingFn }`. Terminal receipts allow replay
without retaining full review bodies; unknown reviews retain the exact request.
First run the allocation-free, IO-free
`calendar_commands.preflight(request)` and check the validated local grant
against `calendar_native.capabilitiesForCommand(command)`. Then load the
account's original invitation and verified identities and close its mail
network session before opening Native; the HTTP client is a singleton. Source
callbacks can return this preloaded data. An absent Calendar capability must
fail before mailbox/network access. The Core branch belongs before generic
mail/cache routing; the module does not register commands by itself.

All requests contain `cmd` and the configured `account`. All commands except
`calendar.list` require the exact `calendarId` returned by the list; the selected
account is not assumed to own the calendar. List entries contain `calendar`,
`canRead`, `canWrite`, and `canFreeBusy`. The nested calendar/event/snapshot types
use the shared domain field names.

| Command | Additional request fields |
| --- | --- |
| `calendar.agenda`, `calendar.freebusy` | `date` (`YYYY-MM-DD`), optional `view` (`day` or `week`, default `day`) and `timeZone` (default selected calendar zone) |
| `calendar.event` | `eventId` |
| `calendar.invitation-plan` | `messageId`, optional host-resolved `attachmentId` |
| `calendar.review` | Same source fields, plus `operationId` |
| `calendar.apply`, `calendar.reconcile` | Saved `operationId` and exact lowercase 64-character `reviewHash` |

The optional `calendar.import`, `calendar.update`, and `calendar.cancel` aliases
use the same saved review and confirmation fields and additionally enforce its
mutation kind. Only advertise commands after Core actually routes them.

`loadInvitationFn(context, allocator, account, request)` returns the original
source and verified account aliases. Empty verified aliases do not broaden
attendee matching; a caller-provided `verifiedAliases` field is refused.
`loadReviewFn(context, allocator, target, operation_id)` returns an owned saved
`Review`. Review preparation calls the existing persistence `preserveFn` and
returns a summary and confirmation hash. Applying a review reloads those exact
saved bytes; caller JSON cannot replace its request body, source, or ETag. A
wrong hash, operation, account, calendar or mutation alias fails before provider
access. Apply refreshes the selected calendar metadata before the service's
existing conflict and durable-claim checks.

Agenda results contain `calendar`, `snapshot`, and `refreshError`; invitation
plans contain `decision`, `invitation`, `resolved`, `timeError`, `lookupComplete`,
`writable`, and any existing `event`/`operation`. Review results add `reviewHash`,
`action`, `uid`, `version`, `eventId`, and `expectedEtag`. Applied results contain
`state` (`applied`, `rejected`, or `unknown`), `providerId`, `reconciled`,
`errorCode`, and any returned event.

For floating times the request must name `startTimeZone`/`endTimeZone` and set
`acceptFloatingTime=true`. Embedded timezone reinterpretation additionally
requires `reinterpretEmbeddedTimezones=true` and an explicit zone for each
endpoint. Common embedded STANDARD/DAYLIGHT rules can be verified automatically:
`calendar_embedded.matches` checks every source and IANA offset transition over
the event interval, with three days of context on either side. It supports
bounded DTSTART/RDATE observances and YEARLY rules with BYMONTH and an ordinal
BYDAY or single BYMONTHDAY, including UTC UNTIL. The proof is limited to events
of at most 366 days and does not enable recurring event writes. An unknown
Windows TZID may use the selected calendar's zone only after that proof succeeds.
DATE values remain civil dates, and DST gaps/folds remain unresolved.
[RFC 5545 timezone observances](https://www.rfc-editor.org/rfc/rfc5545#section-3.6.5).

Unsupported embedded zones remain inspectable with the original source and an
explicit `timeError`; they do not silently inherit the machine zone. The TUI
must explain any reinterpretation before requesting a review.

For `DURATION`, nominal days and weeks advance DTSTART's civil date in its
original verified zone before elapsed hours, minutes and seconds are added.
A local day can therefore span 23 or 25 hours. A derived gap or fold still
requires an explicit decision; all-day values remain civil dates and UTC
values retain UTC semantics. Duration and supported-year bounds still apply.
[RFC 5545 duration ordering](https://www.rfc-editor.org/rfc/rfc5545#section-3.3.6).

## Durable account storage

`Persistence.loadFn` returns the latest tracked source version and operation for
the exact account/calendar/UID identity. A pending unknown operation takes
priority over an older applied receipt. Return strings owned by the supplied
allocator. `preserveFn` saves the complete source and prepared review in the
account's store before a write can be claimed. It must be idempotent for an
identical review and reject replacing a pending operation's source or intent.

These callbacks are a persistence boundary, not an encryption implementation.
A host using the legacy owner-only store still has plaintext private storage;
only an adapter backed by the unlocked vault provides encrypted persistence.
Keep the same durable receipt contract in either mode. Do not describe an
application integration as encrypted before its actual adapter uses the vault.

The `calendar_plan.Journal` adapter must enforce these rules atomically under the
store lock:

1. Claim an identity with a durable `unknown` receipt before returning
   `fresh=true`. Competing operation IDs for an identity with unknown outcome are
   refused. Identical claims return the existing receipt with `fresh=false`.
2. Bind the entire intent: account, calendar ID, UID, recurrence key, source
   sequence and DTSTAMP, source SHA-256, operation ID, mutation kind, event ID,
   ETag and exact request fingerprint. Reject changed receipts.
3. Commit `applied` receipt and tracked source/version/event identity together.
   Preserve unknown if recording the outcome fails. Keep receipts across process
   restart; clearing an in-memory session must not permit replay.
4. Preserve unknown receipts from eviction. Prune superseded applied/rejected
   history only within the host's bounded encrypted-store policy.

The confirmation contains the exact target, operation ID and review hash. The
service checks the source bytes and request hash again, rechecks absence or the
current ETag, preserves the review, and claims unknown before dispatch. A failed
preserve/claim performs no provider mutation. An interrupted response or invalid
success body remains unknown. Repeated execution performs reads only.

Imports and updates reconcile only from a complete UID lookup with the exact
operation marker, source hash, source sequence, organizer and event identity.
A cancellation can reconcile from its exact event's cancelled tombstone; 404
alone leaves the outcome unknown. A new review cannot bypass an unknown receipt
by selecting another operation ID.

An invitation plan with a pending unknown receipt includes `recovery` loaded
from that exact saved review: `account`, `calendarId`, `operationId`,
`reviewHash` and `action`. A restarted TUI can display the unknown outcome and
call `calendar.reconcile` with that confirmation, without creating a new
operation or persisting confirmation hashes in UI settings.

Conditional updates preserve unrelated provider properties and exclude attendee,
conference, attachment and recurrence array replacement. Cancellation uses a
conditional DELETE with `sendUpdates=none`.
[Google patch semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events/patch),
[Google deletion semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events/delete).

Optional `Cache` callbacks load or replace only an exact account/calendar/window
snapshot. The service saves only a complete refresh. On refresh failure it may
return the previous complete snapshot with `stale=true` and a named error; an
empty incomplete page never erases the saved agenda.
If saving a successful fresh snapshot fails, the result retains the fresh
snapshot and exposes `cacheError`; it does not replace valid provider data with
an older snapshot or fail the read solely because the disk quota is full.

## Synthetic verification

`src/calendar_service_tests.zig` exercises this service using literal provider
fixtures and a journal double. Tests assert request order and write counts,
durable claim before dispatch, source/account/calendar/version/hash binding,
unknown-outcome reconciliation, storage failures, pagination exhaustion/cycles,
read/write/availability scope separation, Calendar-specific HTTP failures,
stale-cache retention, DST day/week windows, conditional cancellation and update
preservation. These tests do not authorize or perform production writes.

`src/calendar_commands_tests.zig` exercises source and saved-review callbacks,
JSON validation, exact confirmation binding, Calendar selection and command
repetition. `src/calendar_native_tests.zig` covers the shared native grant gate
and request binding. `tests/calendar_native_http.py` drives
`src/calendar_http_probe.zig` against a local HTTP oracle; it checks actual
methods, bodies, exact `If-Match` bytes, status mapping, no redirected write,
and no replay after an interrupted write. Its fixed synthetic bearer cannot
access production credentials.

`calendar_fixture.Provider` supplies the same transport to actual `--fixtures`
commands. Initialize it with the account, fixture Store root/options, I/O,
backing allocator and current timestamp. Each request opens and closes one
short account transaction. Its three synthetic calendars include primary,
shared-owner and read-only access; agenda reads expand the seeded daily series,
and individual occurrence IDs can be opened. Provider state is a bounded fixed
document available only inside the fixture namespace. Response bytes belong to
the transport caller's allocator.

The fixture provider persists imports, conditional updates and cancellation
tombstones across process invocations. The `calendar-lost-response` scenario
commits each mutation and then reports a disconnected response. A subsequent
apply or reconcile must observe that same mutation without repeating it.
`src/calendar_fixture_tests.zig` combines this provider with the JSON dispatcher
and actual durable account Store, including pagination and stale `If-Match`
acceptance. These synthetic checks do not contact Google or load credentials.
