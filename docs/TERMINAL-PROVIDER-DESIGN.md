# Terminal mail provider design

Research date: 2026-10-05. This document separates API facts from proposed implementation choices. The first implementation uses synthetic fixtures and a separate terminal cache. It does not authorize real Gmail sending, contact changes, calendar changes, new consent, or changes to installed accounts. The bar keeps its existing read-only grant, 30-row snapshots and allocation contract.

## HEY reference

The referenced product is the official [basecamp/hey-cli](https://github.com/basecamp/hey-cli), linked from HEY's own [agent guide](https://help.hey.com/article/1189-using-ai-agents-with-hey) and [CLI/TUI page](https://www.hey.com/agents/). It provides the same mail operations to terminal users and agents. The useful precedent here is shared operations for listing, searching, reading threads, composing, replying, drafts and contacts; calendar browsing, todos and journal features are outside this task.

HEY's [CLI reference](https://github.com/basecamp/hey-cli/blob/main/docs/cli.md) describes explicit account selection, structured output, stable errors, recipient previews, body input through an editor or stdin, and human/agent access to the same readable body. Omagma should use the same provider functions behind its TUI and JSON CLI. A preview must show the exact account, sender, recipients, subject and threading before a mutation. Omagma keeps tokens out of argv and output, uses no browser-cookie authentication, and makes each account explicit rather than choosing an all-account default. These are Omagma choices, not HEY compatibility promises.

## Existing implementation audit

* `src/providers/gmail.zig` verifies the Gmail profile against the selected account for every job, reads at most 30 inbox envelopes, retries one authentication failure, and leaves the unread count unknown when only the count request fails. It does not fetch body MIME parts or retain mail on disk.
* `src/oauth.zig` requests exactly `gmail.readonly` and rejects a returned scope outside that set. PKCE, state, the bounded loopback callback and joined deadlines can be reused, but terminal scope handling must be a distinct policy. The existing bar validator must remain strict.
* `src/keyring.zig` isolates tokens with the service and account attributes. Terminal grants need a distinct credential namespace and grant attributes; they must not replace the bar's token. Secrets continue through bounded stdin/stdout pipes, never command-line arguments, logs, cache or JSON output.
* `src/http_client.zig` restricts HTTPS destinations to Gmail and OAuth, rejects redirects and compression, bounds headers/body/storage, and joins request cancellation. Its request body is currently form-only and 32 KiB; its response cap is 512 KiB. JSON sends, People requests and larger message bodies need an explicit terminal request policy, not a relaxation of the bar wrapper.
* `src/config.zig` owns three bar accounts and their browser profiles. Terminal account/cache/capability settings belong in a separate schema. A message or contact ID is always paired with an account identity; identical IDs in two accounts must remain distinct.

## Capability grants and credentials

Use the following least-permission sets when live terminal access is explicitly enabled later. Google classifies `gmail.readonly` as restricted and `gmail.send` as sensitive. Reading, including body and send-as alias discovery, does not require `gmail.modify`. Sending does not require deleting or changing mailbox labels. [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [send-as aliases](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.settings.sendAs/list).

| Capability | Google permission |
| --- | --- |
| Mail read/search/body/cache | `https://www.googleapis.com/auth/gmail.readonly` |
| Compose/reply/send and invitation reply by mail | Above plus `https://www.googleapis.com/auth/gmail.send` |
| Archive, reversible trash, restore and labels | `https://www.googleapis.com/auth/gmail.modify` instead of readonly/send |
| Google address book read | Add `https://www.googleapis.com/auth/contacts.readonly` |
| Google address book create/update | Add `https://www.googleapis.com/auth/contacts` in place of contacts.readonly |
| Local draft/address book changes in fixture mode | No Google permission |

Google explicitly says installed applications do **not** support incremental authorization. A later capability change needs a complete requested scope set and a separate consent flow; it must not rely on incremental web-app behavior. Preserve granted scopes with the terminal credential identity, require the operation's capability locally, and treat API permission denial as authoritative. Continue checking the Gmail profile identity before persisting a new token. [Desktop OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app).

The implemented terminal Secret Service namespace is `io.github.technologylab_ai.omagma.terminal`, with exact account, OAuth client ID and a SHA-256 identity of the canonical requested scope set. `terminal-grants.json` stores public capability/client metadata; refresh tokens remain in Secret Service. Broader terminal access requires a distinct Desktop OAuth client from the configured bar client: a different keyring label alone does not isolate Google's grant for the same account/client. Creating another Desktop client in the same Google project does not itself grant scopes; the project's existing testing/verification requirements still apply to later consent. Never look up a write token as fallback for the bar. `auth.status` reports metadata without printing secrets. `auth.revoke` clears the selected account's terminal credential and local grant metadata; it does not claim to revoke Google's entire OAuth grant. No new real consent was performed.

## Shared operation boundary

Root owns the shared types, terminal cache/core, CLI and TUI. Pure mail modules own bounded recipients, MIME/header conversion and invitation processing. The provider returns caller-owned bounded data, never borrowed scratch storage that survives a job.

The common operations are `list(account, query, cursor, limit)`, `read(account, message_id)`, `thread(account, thread_id)`, `replyPlan(account, message_id, reply_all)`, `send(account, draft)`, contacts list/search/create/update, and `rsvp(account, message_id, status)`. Each list response includes an explicit continuation cursor and complete/partial state. Each mutation response says which backend acted; a synthetic send is never described as delivered to Google. TUI state, cached state and credentials cannot change an operation's account implicitly.

Proposed pure module types are a mailbox with bounded display name and address; a recipient list capped at 32; a To/Cc/Bcc envelope; borrowed compose fields with explicit reply headers; and an invitation with UID, organizer, attendee, sequence and optional recurrence identifier. Final resource limits belong in shared terminal types. Overflow is a named error or explicit unread body state, never a successful silently truncated message.

## Gmail retrieval and MIME

`messages.list` returns IDs and thread IDs; body/envelope details need `messages.get`. Google allows at most 500 IDs per page, but Omagma should fetch 100 or fewer and stop at a configured cache/job budget. Carry `nextPageToken` explicitly and percent-encode it. A read uses `format=full`, walks the MIME `payload.parts` tree, and reads base64url data; a part whose body has `attachmentId` needs the attachment endpoint. [Message listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list), [message resource](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages), [part bodies](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments).

A snippet is never the full body. Prefer a non-attachment `text/plain` body; use a bounded HTML-to-text conversion for HTML-only mail, preserving paragraph breaks and link destinations. Decode UTF-8 and common ASCII/Latin-1/Windows-1252 content explicitly; unsupported encodings are visible errors. Preserve MIME attachment metadata without automatically downloading arbitrary attachments. Limit nesting, parts, headers, decoded bytes and response bytes independently. Strip terminal escape/control sequences from displayed bodies, including bidi controls, while preserving safe text and newlines. HTML is data and never executes or loads remote resources.

Threads are bounded collections of actual messages, ordered chronologically. A large thread must expose continuation or partial state; it cannot claim to be complete after reaching its message or byte cap. [Thread retrieval](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/get).

## Reply recipients, threading and sending

Reply uses Reply-To when present, otherwise From. Reply-all adds original To and Cc, deduplicates mailboxes, excludes the verified account and known aliases, and never derives recipients from Bcc. Quoted display-name commas and comments must not split a mailbox incorrectly. Reject CR/LF/NUL and malformed addresses in outgoing fields before generating headers. Do not infer aliases by removing dots or plus tags; use explicit verified aliases.

Generate an RFC 5322 message with CRLF, a fresh Message-ID, correct From/To/Cc/Bcc, Date, Subject, MIME-Version and UTF-8 body. Use RFC 2047 encoded words for non-ASCII header text and base64 MIME transfer encoding with bounded line lengths. Gmail accepts a base64url RFC message in the JSON `raw` field and delivers to the envelope header recipients. [Sending guide](https://developers.google.com/workspace/gmail/api/guides/sending), [send endpoint](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send), [message format](https://www.rfc-editor.org/rfc/rfc5322.html), [MIME body encoding](https://www.rfc-editor.org/rfc/rfc2045.html).

To attach a reply to an existing Gmail thread, supply threadId, compliant In-Reply-To/References and a matching subject. Preserve the original Message-ID and reference chain with bounded validation. Missing/invalid source identifiers must not produce a false threading claim. [Gmail thread rules](https://developers.google.com/workspace/gmail/api/guides/threads).

Application choice: never automatically retry a non-idempotent send after a timeout or connection loss that might follow submission. Return an outcome-unknown result and retain the draft plus generated Message-ID for reconciliation. A user can explicitly decide to retry after inspecting the result. Preview and fixture modes never call the real send endpoint.

## Cache beyond 30 messages

The terminal cache is separate from bar snapshots. Proposed limits: at most 10,000 envelope records and 256 MiB of message/contact/draft data per account, a fixed page size, one active bounded job and on-demand body reads. The fixture gate uses at least 96 messages per account and persists more than 30 across process restarts. These are application limits, not Google API limits.

Use owner-only directories/files, an account partition based on a validated local identity rather than mail-derived path text, versioned records, capped individual files, atomic replacement and explicit ownership/symlink checks. Store the account identity in records and verify it on every read. Evict old cache bodies by a bounded policy; do not evict unsent drafts or ambiguous submissions as ordinary cache. Validate paths and lengths before reading, count disk bytes and files, and reject oversized/corrupt entries. Cache clearing applies to one selected account and never clears unrelated credentials. Mail cache is private local user data and must never enter repository fixtures or public diagnostics. Encryption at rest is a separate product decision; file permissions alone do not provide it.

## Address book

People API connections provides personal contacts with names, emailAddresses and metadata. Both contacts.readonly and contacts grant reading. Page/sync tokens must keep the original query parameters; sync tokens expire after seven days and deletion is reported in metadata. A successful write's returned contact is the immediate authoritative result; incremental sync does not provide immediate read-after-write. [Connections API](https://developers.google.com/people/api/rest/v1/people.connections/list).

Create requires contacts; update replaces the explicitly selected fields and requires the CONTACT source metadata/etag. Serialize mutations per account. On failedPrecondition, fetch the current contact and ask for a merge instead of overwriting an unseen update. Keep resourceName, CONTACT source ID/etag and provider account together. Do not edit profile/directory records as personal contacts. [Create contact](https://developers.google.com/people/api/rest/v1/people/createContact), [update contact](https://developers.google.com/people/api/rest/v1/people/updateContact).

Local completion should search the selected account's cache; selecting a contact copies a validated mailbox into the draft. Google search needs an empty-query warmup and a read mask; it is optional when the local cache already has the address book. [Contact search](https://developers.google.com/people/api/rest/v1/people/searchContacts). The fixture implementation tests create/update and stale etag behavior without contacting Google.

## Invitation replies without a calendar UI

Parse a `text/calendar` REQUEST from the message. An iTIP REPLY keeps the original UID, ORGANIZER, SEQUENCE and recurrence instance, identifies only the responding ATTENDEE, sets PARTSTAT to ACCEPTED/TENTATIVE/DECLINED, and writes a current UTC DTSTAMP. Do not increment SEQUENCE for a reply. Fold generated content lines correctly, reject ambiguous multiple events/methods/identities, and reject an invitation where the selected account or explicit alias is not an attendee. [iTIP reply rules](https://www.rfc-editor.org/rfc/rfc5546.html), [iCalendar content lines](https://www.rfc-editor.org/rfc/rfc5545.html).

Send it as an iMIP MIME message to the organizer with `text/calendar; method=REPLY` and matching VCALENDAR METHOD. This uses Gmail's send permission and supports organizers outside Google. The result means an RSVP email was submitted; it does not independently establish the attendee's Google Calendar state. [iMIP transport](https://www.rfc-editor.org/rfc/rfc6047.html).

Direct Calendar API response changes would be a separate capability, require event lookup/identity and Calendar authorization, and must preserve other attendee entries because arrays in a patch replace the entire array. There is no narrow RSVP-only scope in the documented patch endpoint; calendar.events is broader. This task chooses invitation reply mail and requests no Calendar scope. [Event patch](https://developers.google.com/workspace/calendar/api/v3/reference/events/patch).

## Fixture gates before live enablement

Exercise account-scoped pagination/cache restart, complete body retrieval, HTML-only text, common charsets, nested MIME and external body references; recipient parsing, self-alias exclusion, duplicate handling and header injection; compose/reply/reply-all preview and generated MIME; contacts create/update/conflict; accepted/tentative/declined and recurring invitation replies; oversized/corrupt cache, revoked capabilities, interrupted/ambiguous send and account mismatch. Assertions use independent literal RFC messages and invitation fields. Real scopes, real writes and live consent remain untested until separately requested.

## Implemented interfaces and bounded policy

`gmail_decode.normalize(value, allocator, externalBodies)` produces the shared `types.Message`. FULL payloads resolve external textual bodies from the supplied attachment-response map; attachments in normalized DTOs carry base64url data and sanitized basename filenames. METADATA responses may omit body, MIME type and empty labels. RFC 2047 display names decode after recipient parsing, so an encoded comma remains part of one name; oversized names fail instead of silently truncating. Gmail's internal timestamp must be between zero and 253402300799999 milliseconds, through the last millisecond of year 9999. Supported text charsets are UTF-8, US-ASCII, ISO-8859-1 and Windows-1252; others return `UnsupportedCharset`.

`terminal/gmail.execute(io, allocator, config, account, cmd, request)` verifies an enabled configured account, exact credential/grant identity and Gmail profile before dispatch. Each operation owns one HTTP client with the existing 30-second total job deadline and joined 10-second request deadlines. One explicit HTTP 401 permits one refresh/retry; send timeouts, disconnects, server errors and malformed successful receipts yield an unknown outcome rather than an automatic send retry. Listing fetches at most 100 envelopes using METADATA; bodies and attachments are retrieved on demand. Thread reads reject more than 100 messages explicitly and sort successful results chronologically.

Live contact writes invalidate and persist the local contacts cache before dispatch. After the provider validates an applied receipt, the executor returns that contact directly; it performs no additional cache decoding, cache allocation or disk write. The next contacts read refreshes the cache. If encoding a successful live mutation's final response fails, the executor reports `UnknownOutcome` rather than implying the write failed; that error survives even when the error JSON cannot be allocated. Ordinary read and fixture response allocation failures remain `OutOfMemory`. Unknown send journals and their recovery drafts remain available for reconciliation and are never automatically resubmitted.

`dispatchAuthorized` accepts an injected transport for synthetic API tests. Mail send receives `draft` and `operationId`; its deterministic RFC Message-ID binds account plus operation ID so the root's durable operation journal can retain an ambiguous submission. Calendar sends use `invitation.reply` and the root's reviewed `draft` plus `preparedCalendar`. The provider verifies REPLY, attendee, status and organizer destination, preserves the reviewed calendar bytes, and uses the verified responding send-as alias when applicable. Supplied VTIMEZONE components are preserved within a 32 KiB bound. No Calendar API endpoint is used.

Contacts upsert accepts `expectedEtag`, falling back to the contact DTO's etag. It reads the current CONTACT source, rejects a mismatch before PATCH, and carries that source metadata to Google's compare-and-set check. Only names and emailAddresses appear in the update field mask. Google's documented 400 failedPrecondition is a contact conflict. [People update contract](https://developers.google.com/people/api/rest/v1/people/updateContact).

`terminal/auth.run(io, allocator, config, environment, request)` handles `auth.status`, `auth.authorize` and local `auth.revoke`. Its default registry is `$XDG_CONFIG_HOME/omagma/terminal-grants.json` or `$HOME/.config/omagma/terminal-grants.json`; optional `grantFile` and `clientFile` fields select explicit files. Capability names are `mail-read`, `mail-send`, `mail-modify`, `contacts-read`, `contacts-write` and `calendar-rsvp`. Mail read is always required. Modify uses gmail.modify in place of gmail.readonly/send; contacts-write uses contacts in place of contacts.readonly. Local capability gates still prevent actions that were not requested. RSVP-only grants do not enable ordinary compose/send. Bar authorization remains exactly gmail.readonly and cannot store a broader scoped credential.

Registry writes use atomic 0600 replacement. Reads reject final symlinks, nonregular files, group/other permissions and files larger than 64 KiB; they recheck the opened descriptor before bounded streaming parsing. The metadata contains client paths and capability choices even though tokens remain in Secret Service. Existing live configuration is not changed by validation.

Terminal HTTP JSON request/response storage is caller-owned and capped at 3 MiB. The bar's 32 KiB form/512 KiB response policy remains intact. Decoded MIME bodies are capped at 2 MiB, complete RFC messages at 3 MiB, MIME nesting at 16, parts at 128, incoming attachments at 32, outgoing attachments at 16 with a combined 2 MiB decoded cap, outgoing recipients at 32, and calendar data at 128 KiB. Compose attachment DTOs contain base64url bytes, explicit sizes and validated basename/MIME fields; `mime.composeAttachments` converts them to raw MIME parts. The encoder preserves binary octets and emits RFC 2231 UTF-8 filename continuations. Request JSON expansion can make a large outgoing draft exceed the 3 MiB transport cap; that is an explicit pre-submission failure. The fixed HTTP workspace remains 8 MiB and no terminal buffer is added to the bar's static reservation.

User label names resolve through the read-only labels.list projection to Google's opaque IDs before label mutation or filtering. Known system labels use canonical IDs directly. Unknown or ambiguous names fail before a mutation; this implementation does not create labels implicitly. Cached mail/contact state is invalidated before live mutation so a lost response cannot leave an authoritative old local state.

## Future live setup commands

These commands document the implemented interface; they were not run against a real account during development. Keep the existing bar config and its Desktop client unchanged. For broader terminal permission, create a second Desktop OAuth client in the existing Google project and keep its downloaded `installed` JSON outside the repository. Enable People API in that project only if contacts are wanted. Configure the chosen address, enabled state and Chrome profile in the existing Omagma config. Later authorization opens that profile and checks the returned Gmail identity before saving a terminal credential.

```
omagma terminal-auth status --account ACCOUNT --config CONFIG
omagma terminal-auth authorize --account ACCOUNT --config CONFIG \
  --client-file TERMINAL_DESKTOP_JSON \
  --capabilities mail-read,mail-send,contacts-read,contacts-write,calendar-rsvp
omagma terminal-auth revoke --account ACCOUNT --config CONFIG
```

Use `--grant-file FILE` to choose a separate registry, and pass the same option to later `cli`, `agent`, `mail`, `contacts`, `invitations` or `tui` sessions. JSONL requests can explicitly carry `grantFile`; auth authorization additionally carries `clientFile` and a string array `capabilities`. The default grant path is the config directory stated above. Read-only terminal use can fall back to the existing bar credential when no terminal grant exists. `status` shows configured grant metadata rather than proving current connectivity; `revoke` clears local terminal access and leaves the bar credential alone. `--fixtures` permits only synthetic auth status, with no consent or credential mutation.

Live acceptance remains to be performed with a separately authorized test account: real page tokens and metadata; body/attachment/charset boundaries; thread subject/header association; verified aliases; People creation and concurrent edit rejection; explicit successful/uncertain send reconciliation; external-organizer RSVP delivery. Fixture success does not establish Google grant policy, actual recipient delivery, Calendar state or successful provider-side idempotency.

Executed targeted gates used exact Zig 0.17.0, static musl and baseline x86_64 under the parent's host reservation:

```
zig test src/terminal_codec_tests.zig -Odebug -target x86_64-linux-musl -mcpu baseline -lc -static
zig test src/terminal_codec_tests.zig -Osafe -target x86_64-linux-musl -mcpu baseline -lc -static
zig test src/terminal_provider_tests.zig -Odebug -target x86_64-linux-musl -mcpu baseline -lc -static
zig test src/terminal_provider_tests.zig -Osafe -target x86_64-linux-musl -mcpu baseline -lc -static
```

At the recorded targeted gate, codec tests passed 13/13 (including 288 synthetic FULL messages and malformed-limit inputs); provider/auth tests passed 34/34 in both modes. Subsequent parent-coordinated full builds exercise the additional parser, timezone, attachment, date and provider tests; their final receipts are recorded with the overall terminal verification. These targeted runs measured correctness, not process memory or real Google interoperability. No browser consent, Secret Service mutation, live send, contact update, label change or Calendar write was performed by these tests.

Terminal wire qualification uses a test-only loopback POST method with a fixed synthetic bearer, the same JSON request path and 3 MiB terminal limits. `probe-terminal-http` sends a deterministic 128 KiB JSON payload; `probe-terminal-http-oversize` supplies more than 3 MiB and must fail before any TCP connection. The independent [wire harness](../tests/terminal_transport.py) passed all seven cases in the parent's final Debug and Safe runs with Zig 0.17.0 on Linux x86_64/static musl: exact POST/header/body bytes, a response larger than the bar cap, redirect refusal, declared and chunked response caps, joined 10-second cancellation for absent headers and continuously arriving body bytes, and zero accepted TCP connections for an oversized outgoing request. Those checks used no real credentials or provider endpoints and establish wire behavior separately from semantic mocks. Production destination policy remains HTTPS Gmail/OAuth, adding People only through the terminal method.
