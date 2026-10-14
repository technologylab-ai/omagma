# Calendar permissions and account setup

Calendar access is optional for each account. Enable it for the accounts and
calendars you want to use in the native terminal interface. Gmail invitation
inspection and RSVP email continue to use Gmail permissions.

Calendar storage, views and the capabilities below require Omagma 0.2.9 or
later. Version 0.2.8 rejects these Calendar capabilities. Existing mail/contact
setup commands are documented in [account setup](SETUP.md).

## Choose the access needed

The scope URLs in this table are complete and can be pasted into Google Auth
Platform's Data access screen. Existing mail/contact permissions remain part of
the complete terminal grant when you continue using those features.

| Terminal capability | Calendar scopes | Intended use |
| --- | --- | --- |
| `calendar-read` | `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and `https://www.googleapis.com/auth/calendar.events.readonly` | Select subscribed calendars and read their events, subject to each calendar's sharing rules. |
| `calendar-write-owned` | `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and `https://www.googleapis.com/auth/calendar.events.owned` | Find and import invitations into calendars covered by Google's owned-calendar permission. This also permits reading those events. |
| `calendar-write-shared` | `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and `https://www.googleapis.com/auth/calendar.events` | Read and change events on shared calendars where the account has sufficient calendar access. |
| `calendar-freebusy` | `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and `https://www.googleapis.com/auth/calendar.events.freebusy` | Check availability without requesting event titles and descriptions. |
| Existing `calendar-rsvp` | No Calendar scope; the existing Gmail sending permission applies. | Send a reviewed invitation response email to the organizer. |

The minimum Calendar upgrade for importing into your own calendar is
`calendar-write-owned`. Add `calendar-read` when you want an agenda including
shared calendars that you can read but do not own. Add `calendar-write-shared`
only when you intend to write to such a calendar. The shared write permission
subsumes the event read and owned write scopes. Availability-only access is
optional; Google's FreeBusy endpoint lists a different accepted scope set from
Events, so event access alone must not be assumed to authorize it.
[Scope definitions](https://developers.google.com/workspace/calendar/api/auth),
[FreeBusy authorization](https://developers.google.com/workspace/calendar/api/v3/reference/freebusy/query).

Google's event write scopes also permit editing and deletion; there is no
add-only scope for an existing calendar. Omagma still requires a concrete
reviewed action before changing an event. The broader
`https://www.googleapis.com/auth/calendar` scope is not needed for this workflow.
`calendar.app.created` is appropriate only for a separate app-created calendar,
not for adding invitations to your existing primary calendar.
[Calendar API scopes](https://developers.google.com/workspace/calendar/api/auth).

A calendar being visible does not make it writable. A shared calendar may allow
only busy information, public event details, or event editing. An ACL `owner`
role is manager access and is distinct from the calendar's data owner; do not
treat the role alone as proof that the owned-calendar OAuth scope covers it.
Workspace policies may further restrict access. The calendar picker must show
the account, calendar name and effective access, and must not silently change
the destination to another account. CalendarList lists subscriptions; it is
not a directory of every calendar the account could access.
[Sharing and access roles](https://developers.google.com/workspace/calendar/api/concepts/sharing).

## Enable Calendar API in your existing Google project

1. Open [Google Cloud Console](https://console.cloud.google.com/) and select the
   project containing your terminal OAuth registration.
2. Under **APIs & services → Library**, find **Google Calendar API**, open it,
   and choose **Enable**. Keep Gmail API enabled; retain People API if you use
   contacts. API enablement alone does not grant any account access.
3. Open **Google Auth Platform → Data access → Add or remove scopes**. Add the
   exact Calendar scope URLs selected above, using **Manually add scopes** if
   needed, and save. Retain the existing mail/contact scope entries.
4. Under **Audience**, use **External** if accounts come from different
   Workspace organizations or include personal Google accounts. An Internal
   application is limited to its organization. While the project is in
   Testing, add each intended account as a test user. An organization may
   require its administrator to allow the OAuth client and requested scopes.
5. Under **Clients**, reuse the existing terminal **Desktop app** registration.
   If you do not have one, create a Desktop app client and download its JSON to
   a private directory outside the repository, with file mode `0600`.
6. Preserve a working bar/read-only registration. If the terminal currently
   uses that same registration, create a separate terminal Desktop app client
   before requesting broader terminal permissions. Keep `oauthClientFile` for
   the read-only bar and pass the terminal registration with `--client-file`.

Google documents the installed-app PKCE and loopback authorization flow here:
[Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app).
An OAuth Desktop app client is a public client; its downloaded client secret
does not make the installed application a confidential server application.

## Reauthorize the complete terminal capability set

Google explicitly states that incremental authorization is not supported for
installed apps. Omagma must request a new complete desired scope set through
browser consent, rather than adding an `include_granted_scopes` flag to this
flow. Adding scopes in Console or refreshing an old token does not upgrade an
existing grant.
[Installed-app scope selection](https://developers.google.com/identity/protocols/oauth2/native-app#identify-access-scopes).

For a development build exposing the new capabilities, a minimal import grant
would be:

```sh
omagma terminal-auth authorize --account personal@example.com \
  --config /absolute/private/path/config.json \
  --client-file /absolute/private/path/terminal-registration.json \
  --capabilities mail-read,calendar-write-owned
```

To keep the existing full mail/contact workflow and add the calendar agenda and
owned-calendar imports, the complete capability set would be:

```sh
omagma terminal-auth authorize --account work@example.com \
  --config /absolute/private/path/config.json \
  --client-file /absolute/private/path/terminal-registration.json \
  --capabilities mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp,calendar-read,calendar-write-owned
```

Use your existing custom `--grant-file` consistently if one is configured.
Authorize one configured account at a time. Complete consent in that account's
configured browser profile, verify the selected Google account, and approve
the access you selected. A declined or incomplete upgrade must leave the old
local registration and credential available. The new grant becomes active
only after returned scopes, account identity and credential storage are
validated. This protects local state; it cannot promise that Google will never
revoke an older token.

Inspect `omagma terminal-auth status --account work@example.com` with the same
configuration and grant-file arguments, then reopen the TUI. The calendar
picker should show the intended account and destination calendar. Read access
checks can verify setup without creating an event. Do not test by sending an
invitation to other people or importing into a production calendar unless you
have explicitly chosen that action.

If Calendar authorization is refused by your organization, retain mail access
and contact its administrator with the terminal OAuth client ID and the
specific scope list. A busy-only or read-only calendar remains usable for the
features its access permits; it must not appear as an import destination.

## User-owned and future public registrations

The current setup uses your own Google Cloud project and Desktop app client.
A future public, verified Omagma registration can use the same account, scope,
consent and credential-store boundaries. Using a public registration would
change which OAuth client requests consent; it would not remove per-account
approval, Workspace policy, or the need to preserve grant/account identity.
Do not change an existing client or copy credentials to a different client
silently.

Moving a project to Production, enabling Calendar API, and Google OAuth
verification are separate actions. Verification requirements depend on the
complete scope set and deployment; Calendar access does not certify existing
Gmail access. Google may require public app verification for sensitive or
restricted scopes. Data-at-rest protection is an implementation requirement,
not proof that an application has completed Google's review.
[OAuth verification guidance](https://support.google.com/cloud/answer/13464323?hl=en),
[Calendar scope and verification guidance](https://developers.google.com/workspace/calendar/api/auth),
[distribution policy](DISTRIBUTION.md).

Calendar snapshots, original invitations and operation receipts contain private
data. They use the same account-scoped store as mail: owner-only plaintext by
default, or authenticated encrypted records after explicit vault migration and
activation. The vault serves bounded decrypted records while unlocked; migration
preserves original plaintext sources and explicit exports remain plaintext.
Calendar domain/provider modules use host storage callbacks rather than selecting
a credential store or writing side files. See [vault setup](ENCRYPTION.md).

## Import behavior

Adding an invitation and responding to its organizer are separate actions.
Omagma first locates an existing event by its original iCalendar UID, including
hidden invitations, so an event Google already added is reused. A missing
supported invitation uses `events.import` with its original UID and organizer;
Google documents this as adding the attendee's copy without an invitation
email. It does not create a fresh meeting or email every attendee.
[Import method](https://developers.google.com/workspace/calendar/api/v3/reference/events/import),
[attendee import workflow](https://developers.google.com/workspace/calendar/api/concepts/inviting-attendees-to-events#import_a_copy_of_the_event_directly_in_the_attendees_calendar).

The review shows the destination, organizer, attendee, original timezone and
local time. Unresolved embedded or floating timezone definitions require an
explicit decision; calendar dates remain all-day dates. A failed lookup or
unconfirmed write never means “not added.” After a connection loss, Omagma
checks the recorded operation before offering another import. Cached agendas
show their last refresh time and distinguish an unavailable conflict check
from a verified absence of conflicts.
